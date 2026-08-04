# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextAssembler
      ASSEMBLY_POLICY_VERSION = 1

      def initialize(agent:, persistence:, selector: ContextSelector.new)
        @agent = agent
        @persistence = persistence
        @selector = selector
      end

      def build_initial(input:, agent_root:, execution:, config: {}, patch: LLMInputPatch.empty)
        projection = JournalProjection.new(persistence: @persistence, agent_root: agent_root)
        system_text = build_system_text(input)
        tool_set = ToolDefinitionSet.build(@agent)
        model_cfg = apply_model_config_patch(model_config(config), patch.model_config_patch)

        # Estimate mandatory content size so the selector deducts it from the budget.
        current_input_bytes = @persistence.contents.fetch_text(
          execution.metadata.fetch("current_input_ref")
        )
        mandatory_bytes = [
          system_text.to_s,
          current_input_bytes,
          JSON.generate(tool_set.definitions),
          JSON.generate(model_cfg)
        ].join

        selected = @selector.select(
          agent_root: agent_root,
          journal_projection: projection,
          token_budget: @agent.send(:build_token_budget),
          mandatory_bytes: mandatory_bytes
        ) { |content_ref| @persistence.contents.fetch_text(content_ref) }

        segments = []
        if system_text && !system_text.empty?
          segments << segment(
            :instruction,
            :system,
            @persistence.contents.put_text(system_text),
            :chat_message
          )
        end
        selected.each { |record| segments << segment_from_record(record) }

        # Inject additional segments from the hook patch (after history, before input).
        Array(patch.segment_candidates).each do |candidate|
          candidate_ref = @persistence.contents.put_text(candidate.fetch(:content).to_s)
          segments << segment(
            candidate.fetch(:category, :knowledge),
            candidate.fetch(:role, :user),
            candidate_ref,
            :chat_message
          )
        end

        input_ref = execution.metadata.fetch("current_input_ref")
        segments << segment(:current_input, :user, input_ref, :ask_argument)

        model_config_ref = @persistence.contents.put_json(model_cfg)
        tool_definitions_ref = @persistence.contents.put_json(tool_set.definitions)
        store_manifest(
          call_sequence: 1,
          call_mode: :ask,
          segments: segments,
          model_config_ref: model_config_ref,
          tool_definitions_ref: tool_definitions_ref
        )
      end

      # Builds the next LLM Call manifest from the initial manifest and the
      # Execution working Journal. It never inspects RubyLLM::Chat.
      def build_followup(base_manifest:, agent_root:, execution:, patch: LLMInputPatch.empty)
        input_record_id = execution.metadata.fetch("current_input_record_id")
        segments = base_manifest.segments.map do |existing|
          if existing.delivery == :ask_argument
            segment(
              :current_input,
              :user,
              existing.content_ref,
              :chat_message,
              metadata: existing.metadata
            )
          else
            {
              category: existing.category,
              role: existing.role,
              content_ref: existing.content_ref,
              delivery: existing.delivery,
              tool_call_id: existing.tool_call_id,
              metadata: existing.metadata
            }
          end
        end

        execution.working_records.each do |record|
          next unless record.context_candidate
          next unless record.context_generation == agent_root.transcript_generation
          next if record.record_id == input_record_id

          segments << segment_from_record(record)
        end

        store_manifest(
          call_sequence: execution.llm_calls.length + 1,
          call_mode: :complete,
          segments: segments,
          model_config_ref: apply_followup_model_config(base_manifest.model_config_ref, patch),
          tool_definitions_ref: base_manifest.tool_definitions_ref,
          response_schema_ref: patch.response_schema_candidate || base_manifest.response_schema_ref
        )
      end

      private

      def store_manifest(
        call_sequence:,
        call_mode:,
        segments:,
        model_config_ref:,
        tool_definitions_ref:,
        response_schema_ref: nil
      )
        positioned = segments.each_with_index.map do |value, position|
          LLMInputManifest::Segment.new(**value.merge(position: position))
        end
        manifest = LLMInputManifest.new(
          call_sequence: call_sequence,
          call_mode: call_mode,
          segments: positioned,
          model_config_ref: model_config_ref,
          tool_definitions_ref: tool_definitions_ref,
          response_schema_ref: response_schema_ref,
          assembly_policy_version: ASSEMBLY_POLICY_VERSION,
          ruby_llm_version: defined?(RubyLLM::VERSION) ? RubyLLM::VERSION : nil,
          adapter_name: Phronomy.configuration.llm_adapter.class.name
        )
        [manifest, @persistence.contents.put_json(manifest.to_h)]
      end

      def segment_from_record(record)
        segment(
          record.kind,
          record.role,
          record.content_ref,
          :chat_message,
          tool_call_id: record.metadata["tool_call_id"] || record.metadata[:tool_call_id],
          metadata: record.metadata.merge("journal_record_id" => record.record_id)
        )
      end

      def segment(category, role, content_ref, delivery, tool_call_id: nil, metadata: {})
        {
          category: category,
          role: role,
          content_ref: content_ref,
          delivery: delivery,
          tool_call_id: tool_call_id,
          metadata: metadata
        }
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

      def model_config(config)
        {
          "model" => @agent.class.model&.to_s,
          "provider" => @agent.class.provider&.to_s,
          "temperature" => @agent.class.temperature,
          "max_output_tokens" => @agent.class.max_output_tokens,
          "cache_instructions" => !!@agent.class.cache_instructions,
          "parallel_tool_execution" => !!Phronomy.configuration.parallel_tool_execution,
          "thread_id" => config[:thread_id]&.to_s
        }.compact
      end

      def apply_model_config_patch(base, patch_hash)
        return base unless patch_hash
        # Normalize patch keys to strings to match base hash.
        normalized = patch_hash.transform_keys do |k|
          case k
          when :model then "model"
          when :provider then "provider"
          when :temperature then "temperature"
          when :max_output_tokens then "max_output_tokens"
          else k.to_s
          end
        end
        base.merge(normalized).compact
      end

      def apply_followup_model_config(base_ref, patch)
        return base_ref unless patch.model_config_patch
        base = @persistence.contents.fetch_text(base_ref)
        base_hash = JSON.parse(base)
        merged = apply_model_config_patch(base_hash, patch.model_config_patch)
        @persistence.contents.put_json(merged)
      end
    end
  end
end
