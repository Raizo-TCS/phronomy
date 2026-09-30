# frozen_string_literal: true

module Phronomy
  module Context
    # Context preparation framework: policy, plan invariants, canonical input and budget.
    class Assembly
      ASSEMBLY_POLICY_VERSION = 9
      POLICY_ORIGIN_METADATA_KEY = "context_policy_origin"
      POLICY_ITEM_ID_METADATA_KEY = "context_policy_item_id"
      SEMANTIC_CATEGORY_METADATA_KEY = "context_policy_semantic_category"
      CONTENT_FORMAT_METADATA_KEY = "context_policy_content_format"
      CONVERSATION_GROUP_ID_METADATA_KEY = "context_policy_conversation_group_id"
      TRUSTED_HANDOFF_METADATA_KEYS = %w[
        handoff_policy_category
        handoff_provenance
      ].freeze
      HANDOFF_POLICY_CATEGORY_METADATA_KEY = "handoff_policy_category"

      Prepared = Data.define(:input, :plan, :model_config, :call_sequence, :call_mode, :adapter_identity)

      def initialize(tracer: Phronomy::RuntimeSettings.current.tracer)
        @tracer = tracer
      end

      # Executes policy once against an immutable snapshot, outside a save transaction.
      # All policies share validation and canonicalization; callers never replay policy to recover.
      def prepare(input:, policy:, adapter_identity:)
        plan = invoke_policy(policy, input)
        Phronomy::Context::ContextPlanValidator.new.validate!(input: input, plan: plan)
        Prepared.new(
          input: input, plan: plan, model_config: input.model_config,
          call_sequence: input.call_sequence, call_mode: input.call_mode,
          adapter_identity: Phronomy::Values::Immutable.copy(adapter_identity)
        )
      end

      def store(prepared, contents:)
        unless prepared.is_a?(Prepared)
          raise ArgumentError, "Context::Assembly#store expected Context::Assembly::Prepared"
        end

        plan = Phronomy::Context::ContextPlanValidator.new.validate!(input: prepared.input, plan: prepared.plan)
        segments = []
        plan.instruction.each do |item|
          segments << segment_from_content_item(
            item,
            contents: contents,
            additional_metadata: {SEMANTIC_CATEGORY_METADATA_KEY => "instruction"}
          )
        end
        plan.knowledge.each do |item|
          segments << segment_from_content_item(
            item,
            contents: contents,
            additional_metadata: {SEMANTIC_CATEGORY_METADATA_KEY => "knowledge"}
          )
        end
        plan.conversation.each_with_index do |group, group_index|
          group_metadata = {
            SEMANTIC_CATEGORY_METADATA_KEY => "conversation",
            CONVERSATION_GROUP_ID_METADATA_KEY =>
              "conversation:#{prepared.call_sequence}:#{group_index}"
          }
          if tool_exchange_group?(group)
            group_metadata[HANDOFF_POLICY_CATEGORY_METADATA_KEY] = "tool_exchanges"
          end

          group.each do |item|
            segments << segment_from_content_item(
              item,
              contents: contents,
              additional_metadata: group_metadata
            )
          end
        end

        selected_tool_definitions = plan.tools.map(&:definition)
        Phronomy::Context::FinalBudgetValidator.new(
          content_loader: lambda { |ref| fetch_content_from(contents, ref) }
        ).validate!(
          token_budget: prepared.input.token_budget,
          segments: segments,
          extra_values: [selected_tool_definitions]
        )

        store_manifest(
          contents: contents,
          call_sequence: prepared.call_sequence,
          call_mode: prepared.call_mode,
          segments: segments,
          model_config_ref: contents.put_json(prepared.model_config),
          tool_definitions_ref: contents.put_json(selected_tool_definitions),
          adapter_identity: prepared.adapter_identity
        )
      end

      private

      def invoke_policy(policy, policy_input)
        tracer = @tracer
        span = tracer.start_span(
          "context_policy",
          agent_id: policy_input.agent_id,
          execution_id: policy_input.execution_id,
          call_sequence: policy_input.call_sequence,
          policy_class: policy.class.name || policy.class.to_s,
          instruction_count: policy_input.instruction.length,
          knowledge_count: policy_input.knowledge.length,
          tool_count: policy_input.tools.length,
          conversation_group_count: policy_input.conversation.length
        )
        result = policy.call(policy_input)
        tracer.finish_span(span)
        result
      rescue => error
        tracer&.finish_span(span, error: error) if defined?(span) && span
        raise
      end

      def store_manifest(
        contents:,
        call_sequence:,
        call_mode:,
        segments:,
        model_config_ref:,
        tool_definitions_ref:,
        adapter_identity:
      )
        positioned = segments.each_with_index.map do |value, position|
          Phronomy::Context::LLMInputManifest::Segment.new(**value.merge(position: position))
        end
        manifest = Phronomy::Context::LLMInputManifest.new(
          call_sequence: call_sequence,
          call_mode: call_mode,
          segments: positioned,
          model_config_ref: model_config_ref,
          tool_definitions_ref: tool_definitions_ref,
          assembly_policy_version: ASSEMBLY_POLICY_VERSION,
          ruby_llm_version: adapter_identity["sdk_version"],
          adapter_name: adapter_identity["adapter_name"]
        )
        [manifest, contents.put_json(manifest.to_h)]
      end

      def segment_from_content_item(item, contents:, additional_metadata: {})
        content_ref = item.provenance.content_ref || store_item_content(item, contents)
        metadata = sanitized_item_metadata(item).merge(additional_metadata).merge(
          CONTENT_FORMAT_METADATA_KEY => item.content_format.to_s,
          POLICY_ITEM_ID_METADATA_KEY => item.id,
          POLICY_ORIGIN_METADATA_KEY => item.provenance.origin.to_s,
          "journal_record_id" => item.provenance.record_id,
          "source_agent_id" => item.provenance.agent_id,
          "source_execution_id" => item.provenance.execution_id,
          "llm_call_id" => item.provenance.llm_call_id
        ).compact

        {
          category: item.kind,
          role: item.role,
          content_ref: content_ref,
          delivery: item.respond_to?(:delivery) ? item.delivery : :chat_message,
          tool_call_id: item.respond_to?(:tool_call_id) ? item.tool_call_id : nil,
          metadata: metadata
        }
      end

      def sanitized_item_metadata(item)
        raw = item.metadata.to_h.transform_keys(&:to_s)
        # :working origin is Phronomy-controlled (from InitialPreparation),
        # so handoff routing metadata on working records is equally trusted.
        trusted_handoff = if item.provenance.origin == :handoff || item.provenance.origin == :working
          raw.slice(*TRUSTED_HANDOFF_METADATA_KEYS)
        else
          {}
        end

        raw.except(*Phronomy::Context::ContextPolicyInput::FRAMEWORK_METADATA_KEYS)
          .merge(trusted_handoff)
      end

      def tool_exchange_group?(group)
        Array(group).any? do |item|
          item.kind == :assistant_message && !item.tool_call_ids.empty?
        end && Array(group).any? { |item| item.kind == :tool_message }
      end

      def store_item_content(item, contents)
        if item.content_format == :json
          contents.put_json(item.content)
        else
          contents.put_text(item.content.to_s)
        end
      end

      def fetch_content_from(contents, ref)
        contents.fetch_text(ref)
      rescue
        contents.fetch(ref)
      end
    end
  end
end
