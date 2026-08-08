# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextAssembler
      ASSEMBLY_POLICY_VERSION = 5
      SEGMENT_ORIGIN_METADATA_KEY = "phronomy_origin"
      BEFORE_LLM_INPUT_ORIGIN = "before_llm_input"

      def initialize(
        agent:,
        persistence:,
        policy: ContextPolicies::Default.new,
        candidate_resolver: nil
      )
        @agent = agent
        @persistence = persistence
        @policy = policy
        @candidate_resolver = candidate_resolver || ContextCandidateResolver.new(
          content_loader: method(:fetch_content)
        )
      end

      def build_initial(input:, agent_root:, execution:, config: {}, patch: LLMInputPatch.empty)
        projection = JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        model_cfg = effective_model_config(config, patch)
        tool_set = ToolDefinitionSet.build(@agent)
        system_text = build_system_text(input)
        hook_candidates = normalize_candidates(patch.segment_candidates)
        input_ref = execution.metadata.fetch("current_input_ref")
        current_input = @persistence.contents.fetch_text(input_ref)
        excluded = [execution.metadata["current_input_record_id"]].compact

        base_segments = []
        unless system_text.to_s.empty?
          base_segments << text_segment(:instruction, :system, system_text)
        end

        assemble(
          agent_root: agent_root,
          execution: execution,
          call_sequence: 1,
          call_mode: :ask,
          previous_manifest: nil,
          model_config: model_cfg,
          tool_definitions: tool_set.definitions,
          tool_definitions_ref: nil,
          prior_records: projection.transcript_records,
          working_records: execution.working_records,
          excluded_record_ids: excluded,
          base_segments: base_segments,
          hook_candidates: hook_candidates,
          current_input_segment: segment(:current_input, :user, input_ref, :ask_argument),
          mandatory_values: [system_text, current_input, tool_set.definitions] +
            hook_candidates.map { |candidate| candidate.fetch(:content) }
        )
      end

      def build_followup(
        base_manifest:,
        agent_root:,
        execution:,
        config: {},
        patch: LLMInputPatch.empty
      )
        projection = JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        model_cfg = effective_model_config(config, patch)
        hook_candidates = normalize_candidates(patch.segment_candidates)
        system_segments = base_manifest.segments.select do |segment|
          segment.role == :system && !before_llm_input_segment?(segment)
        end
        tool_definitions = base_manifest.tool_definitions_ref ?
          fetch_json(base_manifest.tool_definitions_ref) : []

        assemble(
          agent_root: agent_root,
          execution: execution,
          call_sequence: execution.llm_calls.length + 1,
          call_mode: :complete,
          previous_manifest: base_manifest,
          model_config: model_cfg,
          tool_definitions: tool_definitions,
          tool_definitions_ref: base_manifest.tool_definitions_ref,
          prior_records: projection.transcript_records,
          working_records: execution.working_records,
          excluded_record_ids: [],
          base_segments: system_segments.map { |existing| segment_hash(existing) },
          hook_candidates: hook_candidates,
          current_input_segment: nil,
          mandatory_values: system_segments.map { |segment| fetch_content(segment.content_ref) } +
            hook_candidates.map { |candidate| candidate.fetch(:content) } +
            [tool_definitions]
        )
      end

      private

      def assemble(
        agent_root:,
        execution:,
        call_sequence:,
        call_mode:,
        previous_manifest:,
        model_config:,
        tool_definitions:,
        tool_definitions_ref:,
        prior_records:,
        working_records:,
        excluded_record_ids:,
        base_segments:,
        hook_candidates:,
        current_input_segment:,
        mandatory_values:
      )
        generation = agent_root.transcript_generation
        eligible_working = Array(working_records).select do |record|
          record.context_candidate && record.context_generation == generation
        end
        candidates = @candidate_resolver.resolve(
          prior_records: prior_records,
          working_records: eligible_working,
          excluded_record_ids: excluded_record_ids
        )
        token_budget = TokenBudgetResolver.new(agent: @agent).resolve(model_config)
        mandatory_token_estimate = estimate_values(mandatory_values)
        parts = context_parts
        request = ContextRequest.new(
          agent_id: agent_root.agent_id,
          execution_id: execution.execution_id,
          call_sequence: call_sequence,
          call_mode: call_mode,
          candidates: candidates,
          token_budget: token_budget,
          model_config: model_config,
          previous_manifest: previous_manifest,
          required_coverage: [],
          parts: parts,
          metadata: {"mandatory_token_estimate" => mandatory_token_estimate}
        )
        plan = @policy.call(request)
        validated = ContextPlanValidator.new.validate!(request: request, plan: plan)
        unless validated.plan.derived_contents.empty?
          raise Phronomy::ConfigurationError,
            "Derived Context persistence is not enabled in Context Policy phase 1-4"
        end

        segments = Array(base_segments).dup
        append_candidates(segments, hook_candidates, before_history: true)
        validated.selected_candidates
          .sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }
          .each { |candidate| segments << segment_from_candidate(candidate) }
        append_candidates(segments, hook_candidates, before_history: false)
        segments << current_input_segment if current_input_segment

        ContextParts::Validators::FinalBudgetValidator.new(
          content_loader: method(:fetch_content)
        ).validate!(
          token_budget: token_budget,
          segments: segments,
          extra_values: [tool_definitions]
        )

        store_manifest(
          call_sequence: call_sequence,
          call_mode: call_mode,
          segments: segments,
          model_config_ref: @persistence.contents.put_json(model_config),
          tool_definitions_ref: tool_definitions_ref ||
            @persistence.contents.put_json(tool_definitions)
        )
      end

      def context_parts
        {
          unit_builder: ContextParts::UnitBuilders::DependencyAwareUnitBuilder.new,
          required_context_resolver: ContextParts::Requirements::RequiredContextResolver.new,
          recent_first_selector: ContextParts::Selectors::RecentFirstSelector.new,
          token_budget_packer: ContextParts::Budget::TokenBudgetPacker.new
        }.freeze
      end

      def estimate_values(values)
        Array(values).sum do |value|
          bytes = value.is_a?(String) ? value : Phronomy::CanonicalJSON.dump(value)
          Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes)
        end
      end

      def store_manifest(call_sequence:, call_mode:, segments:, model_config_ref:, tool_definitions_ref:)
        positioned = segments.each_with_index.map do |value, position|
          LLMInputManifest::Segment.new(**value.merge(position: position))
        end
        manifest = LLMInputManifest.new(
          call_sequence: call_sequence,
          call_mode: call_mode,
          segments: positioned,
          model_config_ref: model_config_ref,
          tool_definitions_ref: tool_definitions_ref,
          assembly_policy_version: ASSEMBLY_POLICY_VERSION,
          ruby_llm_version: defined?(RubyLLM::VERSION) ? RubyLLM::VERSION : nil,
          adapter_name: Phronomy.configuration.llm_adapter.class.name
        )
        [manifest, @persistence.contents.put_json(manifest.to_h)]
      end

      def effective_model_config(config, patch)
        apply_model_config_patch(model_config(config), patch.model_config_patch)
      end

      def model_config(config)
        {
          "model" => @agent.class.model&.to_s,
          "provider" => @agent.class.provider&.to_s,
          "temperature" => @agent.class.temperature,
          "max_output_tokens" => @agent.class.max_output_tokens,
          "context_window" => @agent.class.context_window,
          "cache_instructions" => !!@agent.class.cache_instructions,
          "parallel_tool_execution" => !!Phronomy.configuration.parallel_tool_execution,
          "thread_id" => config[:thread_id]&.to_s
        }.compact
      end

      def apply_model_config_patch(base, patch)
        return base unless patch
        base.merge(patch.to_h.transform_keys(&:to_s)).compact
      end

      def normalize_candidates(candidates)
        Array(candidates).map do |candidate|
          hash = candidate.to_h
          content = hash.fetch(:content) { hash.fetch("content") }
          category = (hash[:category] || hash["category"] || :knowledge).to_sym
          role = (hash[:role] || hash["role"] || default_role(category)).to_sym
          {content: content.to_s, category: category, role: role}
        end
      end

      def append_candidates(segments, candidates, before_history:)
        candidates.each do |candidate|
          early = %i[instruction structured_state knowledge memory summary].include?(candidate[:category])
          next unless early == before_history
          segments << text_segment(
            candidate[:category],
            candidate[:role],
            candidate[:content],
            metadata: {SEGMENT_ORIGIN_METADATA_KEY => BEFORE_LLM_INPUT_ORIGIN}
          )
        end
      end

      def default_role(category)
        category == :instruction ? :system : :user
      end

      def text_segment(category, role, content, metadata: {})
        segment(
          category, role, @persistence.contents.put_text(content.to_s), :chat_message,
          metadata: metadata
        )
      end

      def before_llm_input_segment?(segment)
        segment.metadata[SEGMENT_ORIGIN_METADATA_KEY] == BEFORE_LLM_INPUT_ORIGIN
      end

      def segment_from_candidate(candidate)
        metadata = candidate.metadata.reject do |key, _value|
          %w[estimated_tokens source_kind source_sequence].include?(key.to_s)
        end
        metadata = metadata.merge(
          "journal_record_id" => candidate.record_id,
          "journal_sequence" => candidate.metadata["source_sequence"],
          "llm_call_id" => candidate.llm_call_id
        ).compact
        segment(
          candidate.category,
          candidate.role,
          candidate.content_ref,
          :chat_message,
          tool_call_id: candidate.tool_call_id,
          metadata: metadata
        )
      end

      def segment_hash(existing)
        {
          category: existing.category, role: existing.role,
          content_ref: existing.content_ref, delivery: existing.delivery,
          tool_call_id: existing.tool_call_id, metadata: existing.metadata
        }
      end

      def segment(category, role, content_ref, delivery, tool_call_id: nil, metadata: {})
        {category: category, role: role, content_ref: content_ref, delivery: delivery,
         tool_call_id: tool_call_id, metadata: metadata}
      end

      def fetch_json(ref)
        Phronomy::CanonicalJSON.load(@persistence.contents.fetch(ref))
      end

      def fetch_content(ref)
        @persistence.contents.fetch_text(ref)
      rescue
        @persistence.contents.fetch(ref)
      end

      def build_system_text(input)
        instruction = @agent.send(:build_instructions, input)
        knowledge = @agent.class.static_knowledge_chunks + @agent.send(:instance_knowledge_chunks)
        parts = [instruction]
        knowledge.each do |chunk|
          parts << Phronomy::LlmContextWindow::Assembler.xml_tag(
            chunk[:content], type: chunk[:type] || :static, trusted: true
          )
        end
        parts.compact.join("\n\n")
      end
    end
  end
end
