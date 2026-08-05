# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextAssembler
      ASSEMBLY_POLICY_VERSION = 2

      def initialize(agent:, persistence:, selector: ContextSelector.new)
        @agent = agent
        @persistence = persistence
        @selector = selector
      end

      def build_initial(input:, agent_root:, execution:, config: {}, patch: LLMInputPatch.empty)
        projection = JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        model_cfg = effective_model_config(config, patch)
        tool_set = ToolDefinitionSet.build(@agent)
        system_text = build_system_text(input)
        candidates = normalize_candidates(patch.segment_candidates)
        input_ref = execution.metadata.fetch("current_input_ref")
        current_input = @persistence.contents.fetch_text(input_ref)

        selected = select_prior(
          agent_root: agent_root,
          projection: projection,
          model_config: model_cfg,
          mandatory_values: [system_text, current_input, tool_set.definitions, model_cfg] +
            candidates.map { |candidate| candidate.fetch(:content) }
        )

        segments = []
        segments << text_segment(:instruction, :system, system_text) unless system_text.to_s.empty?
        append_candidates(segments, candidates, before_history: true)
        selected.each { |record| segments << segment_from_record(record) }
        append_candidates(segments, candidates, before_history: false)
        segments << segment(:current_input, :user, input_ref, :ask_argument)

        store_manifest(
          call_sequence: 1,
          call_mode: :ask,
          segments: segments,
          model_config_ref: @persistence.contents.put_json(model_cfg),
          tool_definitions_ref: @persistence.contents.put_json(tool_set.definitions)
        )
      end

      def build_followup(base_manifest:, agent_root:, execution:, patch: LLMInputPatch.empty)
        projection = JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        base_model = fetch_json(base_manifest.model_config_ref)
        model_cfg = apply_model_config_patch(base_model, patch.model_config_patch)
        candidates = normalize_candidates(patch.segment_candidates)
        system_segments = base_manifest.segments.select { |s| s.role == :system }
        working_records = execution.working_records.select do |record|
          record.context_candidate &&
            record.context_generation == agent_root.transcript_generation
        end
        tool_definitions = base_manifest.tool_definitions_ref ?
          fetch_json(base_manifest.tool_definitions_ref) : []

        mandatory_values = system_segments.map { |s| fetch_content(s.content_ref) } +
          candidates.map { |candidate| candidate.fetch(:content) } +
          working_records.map { |record| fetch_content(record.content_ref) } +
          [tool_definitions, model_cfg]
        selected = select_prior(
          agent_root: agent_root,
          projection: projection,
          model_config: model_cfg,
          mandatory_values: mandatory_values
        )

        segments = system_segments.map { |existing| segment_hash(existing) }
        append_candidates(segments, candidates, before_history: true)
        selected.each { |record| segments << segment_from_record(record) }
        working_records.each { |record| segments << segment_from_record(record) }
        append_candidates(segments, candidates, before_history: false)

        store_manifest(
          call_sequence: execution.llm_calls.length + 1,
          call_mode: :complete,
          segments: segments,
          model_config_ref: @persistence.contents.put_json(model_cfg),
          tool_definitions_ref: base_manifest.tool_definitions_ref
        )
      end

      private

      def select_prior(agent_root:, projection:, model_config:, mandatory_values:)
        mandatory_text = mandatory_values.map { |value|
          value.is_a?(String) ? value : Phronomy::CanonicalJSON.dump(value)
        }.join("\n")
        @selector.select(
          agent_root: agent_root,
          journal_projection: projection,
          token_budget: TokenBudgetResolver.new(agent: @agent).resolve(model_config),
          mandatory_bytes: mandatory_text
        ) { |content_ref| fetch_content(content_ref) }
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
          segments << text_segment(candidate[:category], candidate[:role], candidate[:content])
        end
      end

      def default_role(category)
        category == :instruction ? :system : :user
      end

      def text_segment(category, role, content)
        segment(category, role, @persistence.contents.put_text(content.to_s), :chat_message)
      end

      def segment_from_record(record)
        segment(
          record.kind, record.role, record.content_ref, :chat_message,
          tool_call_id: record.metadata["tool_call_id"] || record.metadata[:tool_call_id],
          metadata: record.metadata.merge("journal_record_id" => record.record_id)
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
