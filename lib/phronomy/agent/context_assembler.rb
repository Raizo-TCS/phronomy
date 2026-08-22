# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextAssembler
      ASSEMBLY_POLICY_VERSION = 7
      SEGMENT_ORIGIN_METADATA_KEY = "phronomy_origin"
      BEFORE_LLM_INPUT_ORIGIN = "before_llm_input"
      HANDOFF_CONTEXT_ORIGIN = "handoff_context"
      EARLY_CONTEXT_CATEGORIES = %i[
        instruction structured_state knowledge memory summary
      ].freeze

      def initialize(
        agent:,
        persistence:,
        policy: ContextPolicies::Default.new,
        candidate_resolver: nil,
        journal_records: nil
      )
        @agent = agent
        @persistence = persistence
        @policy = policy
        @journal_records = journal_records
        @candidate_resolver = candidate_resolver || ContextCandidateResolver.new(
          content_loader: method(:fetch_content)
        )
      end

      def build_initial(input:, agent_root:, execution:, config: {}, patch: LLMInputPatch.empty)
        projection = journal_projection(agent_root)
        model_cfg = effective_model_config(config, patch)
        tool_set = ToolDefinitionSet.build(
          @agent,
          additional_tools: handoff_tool_classes(config)
        )
        system_text = build_system_text(input)
        hook_candidates = normalize_candidates(patch.segment_candidates)
        input_ref = execution.metadata.fetch("current_input_ref")
        current_input = @persistence.contents.fetch_text(input_ref)
        excluded = [execution.metadata["current_input_record_id"]].compact
        handoff_context = config[:phronomy_handoff_context]

        base_segments = []
        unless system_text.to_s.empty?
          base_segments << text_segment(:instruction, :system, system_text)
        end
        if handoff_context
          base_segments << text_segment(
            :handoff_responsibility,
            :user,
            handoff_context.responsibility,
            metadata: {
              SEGMENT_ORIGIN_METADATA_KEY => HANDOFF_CONTEXT_ORIGIN
            }
          )
        end

        current_input_metadata = {
          "source_agent_id" => agent_root.agent_id,
          "source_execution_id" => execution.execution_id,
          "handoff_policy_category" => "current_request"
        }

        assemble(
          agent_root: agent_root,
          execution: execution,
          call_sequence: 1,
          call_mode: :ask,
          previous_manifest: nil,
          model_config: model_cfg,
          tool_definitions: tool_set.definitions,
          tool_definitions_ref: nil,
          prior_records: projection.context_records,
          working_records: execution.working_records,
          excluded_record_ids: excluded,
          base_segments: base_segments,
          hook_candidates: hook_candidates,
          inbound_handoff_context: handoff_context,
          current_input_segment: segment(
            :current_input,
            :user,
            input_ref,
            :ask_argument,
            metadata: current_input_metadata
          ),
          mandatory_values: [
            system_text,
            handoff_context&.responsibility,
            current_input,
            tool_set.definitions
          ].compact
        )
      end

      def build_followup(
        base_manifest:,
        agent_root:,
        execution:,
        config: {},
        patch: LLMInputPatch.empty
      )
        projection = journal_projection(agent_root)
        model_cfg = effective_model_config(config, patch)
        hook_candidates = normalize_candidates(patch.segment_candidates)
        base_context_segments = base_manifest.segments.select do |segment|
          (segment.role == :system && !before_llm_input_segment?(segment)) ||
            segment.category.to_sym == :handoff_responsibility
        end
        tool_definitions = base_manifest.tool_definitions_ref ?
          fetch_json(base_manifest.tool_definitions_ref) : []
        handoff_context = config[:phronomy_handoff_context]

        assemble(
          agent_root: agent_root,
          execution: execution,
          call_sequence: execution.llm_calls.length + 1,
          call_mode: :complete,
          previous_manifest: base_manifest,
          model_config: model_cfg,
          tool_definitions: tool_definitions,
          tool_definitions_ref: base_manifest.tool_definitions_ref,
          prior_records: projection.context_records,
          working_records: execution.working_records,
          excluded_record_ids: [],
          base_segments: base_context_segments.map { |existing| segment_hash(existing) },
          hook_candidates: hook_candidates,
          inbound_handoff_context: handoff_context,
          current_input_segment: nil,
          mandatory_values: base_context_segments.map { |value| fetch_content(value.content_ref) } +
            [tool_definitions]
        )
      end

      private

      def journal_projection(agent_root)
        if @journal_records
          JournalProjection.new(agent_root: agent_root, records: @journal_records)
        else
          JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        end
      end

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
        inbound_handoff_context:,
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
        candidates = merge_hook_candidates(
          candidates,
          hook_candidates,
          agent_root: agent_root,
          execution: execution,
          call_sequence: call_sequence
        )
        candidates = merge_handoff_candidates(
          candidates,
          inbound_handoff_context,
          execution: execution
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

        selected_candidates = validated.selected_candidates.sort_by do |candidate|
          [candidate.sequence || 0, candidate.candidate_id]
        end
        unit_by_candidate = validated.selected_units.each_with_object({}) do |unit, result|
          unit.candidate_ids.each { |candidate_id| result[candidate_id] = unit }
        end

        segments = Array(base_segments).dup
        append_selected_candidates(
          segments,
          selected_candidates,
          unit_by_candidate: unit_by_candidate,
          before_history: true
        )
        append_selected_candidates(
          segments,
          selected_candidates,
          unit_by_candidate: unit_by_candidate,
          before_history: false
        )
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
          unit_builder: Selection::UnitBuilders::DependencyAwareUnitBuilder.new,
          required_context_resolver: ContextParts::Requirements::RequiredContextResolver.new,
          recent_first_selector: Selection::Selectors::RecentFirstSelector.new,
          token_budget_packer: ContextParts::Budget::TokenBudgetPacker.new
        }.freeze
      end

      def handoff_tool_classes(config)
        Array(config[:phronomy_handoff_bindings]).map(&:tool_class).freeze
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
          metadata = hash[:metadata] || hash["metadata"] || {}
          {
            content: content.to_s,
            category: category,
            role: role,
            metadata: metadata.to_h.transform_keys(&:to_s)
          }
        end
      end

      def merge_hook_candidates(candidates, hooks, agent_root:, execution:, call_sequence:)
        next_sequence = Array(candidates).filter_map(&:sequence).max.to_i
        generated = hooks.each_with_index.map do |hook, index|
          content_ref = @persistence.contents.put_text(hook.fetch(:content))
          metadata = hook.fetch(:metadata).merge(
            SEGMENT_ORIGIN_METADATA_KEY => BEFORE_LLM_INPUT_ORIGIN,
            "estimated_tokens" => Phronomy::LlmContextWindow::TokenEstimator.estimate(
              fetch_content(content_ref)
            ),
            "source_kind" => "hook"
          )
          Selection::Candidate.new(
            candidate_id: "hook:#{execution.execution_id}:#{call_sequence}:#{index}",
            source_kind: :hook,
            category: hook.fetch(:category),
            role: hook.fetch(:role),
            content_ref: content_ref,
            record_id: nil,
            agent_id: agent_root.agent_id,
            execution_id: execution.execution_id,
            llm_call_id: nil,
            tool_call_id: nil,
            sequence: next_sequence + index + 1,
            constraint: Selection::Constraint.selectable(origin: :context_policy),
            priority: 0,
            metadata: metadata
          )
        end
        (Array(candidates) + generated)
          .sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }
          .freeze
      end

      def merge_handoff_candidates(candidates, handoff_context, execution:)
        return Array(candidates).freeze unless handoff_context

        unless handoff_context.is_a?(Phronomy::MultiAgent::HandoffContext)
          raise ArgumentError, "phronomy_handoff_context must be a HandoffContext"
        end

        next_sequence = Array(candidates).filter_map(&:sequence).max.to_i
        transferred = handoff_context.items.each_with_index.map do |item, index|
          content_ref = if item.content_format == :json
            @persistence.contents.put_json(item.content)
          else
            @persistence.contents.put_text(item.content.to_s)
          end
          metadata = item.metadata.merge(
            SEGMENT_ORIGIN_METADATA_KEY => HANDOFF_CONTEXT_ORIGIN,
            "estimated_tokens" => Phronomy::LlmContextWindow::TokenEstimator.estimate(
              fetch_content(content_ref)
            ),
            "source_kind" => "handoff",
            "handoff_policy_category" => item.policy_category.to_s,
            "handoff_provenance" => item.provenance.to_h
          )

          Selection::Candidate.new(
            candidate_id: "handoff:#{execution.execution_id}:#{index}:#{item.provenance.origin_record_id || item.provenance.origin_tool_call_id || index}",
            source_kind: :handoff,
            category: item.candidate_category,
            role: item.role,
            content_ref: content_ref,
            record_id: nil,
            agent_id: item.provenance.origin_agent_id,
            execution_id: execution.execution_id,
            llm_call_id: item.provenance.origin_llm_call_id,
            tool_call_id: item.tool_call_id,
            sequence: next_sequence + index + 1,
            constraint: Selection::Constraint.selectable(origin: :handoff_context),
            priority: 50,
            metadata: metadata
          )
        end

        (Array(candidates) + transferred)
          .sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }
          .freeze
      end

      def append_selected_candidates(segments, candidates, unit_by_candidate:, before_history:)
        candidates.each do |candidate|
          early = EARLY_CONTEXT_CATEGORIES.include?(candidate.category)
          next unless early == before_history

          unit = unit_by_candidate[candidate.candidate_id]
          segments << segment_from_candidate(candidate, unit: unit)
        end
      end

      def default_role(category)
        (category == :instruction) ? :system : :user
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

      def segment_from_candidate(candidate, unit:)
        metadata = candidate.metadata.reject do |key, _value|
          %w[estimated_tokens source_kind source_sequence].include?(key.to_s)
        end
        metadata = metadata.merge(
          "journal_record_id" => candidate.record_id,
          "journal_sequence" => candidate.metadata["source_sequence"],
          "source_agent_id" => candidate.agent_id,
          "source_execution_id" => candidate.execution_id,
          "llm_call_id" => candidate.llm_call_id,
          "selection_candidate_id" => candidate.candidate_id,
          "selection_unit_id" => unit&.unit_id,
          "selection_unit_kind" => unit&.kind&.to_s,
          "handoff_policy_category" => handoff_policy_category(candidate, unit)&.to_s
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

      def handoff_policy_category(candidate, unit)
        explicit = candidate.metadata["handoff_policy_category"] ||
          candidate.metadata[:handoff_policy_category]
        return explicit.to_sym if explicit
        return :tool_exchanges if unit&.kind == :tool_exchange
        return :knowledge if candidate.category == :knowledge

        case candidate.category
        when :external_message, :assistant_message, :tool_message,
             :memory, :summary, :structured_state
          :history
        end
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
        @agent.send(:build_instructions, input)
      end
    end
  end
end
