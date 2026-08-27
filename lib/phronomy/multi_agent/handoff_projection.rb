# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class HandoffProjection
      CONTROL_CATEGORIES = %i[instruction handoff_responsibility].freeze
      JSON_CATEGORIES = %i[assistant_message tool_message].freeze

      def build(request:, manifest:, persistence:, source_agent:)
        unless request.is_a?(HandoffRequest)
          raise ArgumentError, "request must be a HandoffRequest"
        end
        unless manifest.is_a?(Phronomy::Agent::LLMInputManifest)
          raise ArgumentError, "manifest must be an LLMInputManifest"
        end

        groups = project_visible_groups(manifest)
        selected = groups.values.select do |group|
          include_group?(request, group.fetch(:policy_category))
        end

        items = selected.flat_map do |group|
          group.fetch(:segments).map do |segment|
            materialize_item(
              segment,
              policy_category: group.fetch(:policy_category),
              persistence: persistence,
              source_agent: source_agent,
              target_agent: request.handoff.target_agent
            )
          end
        end

        HandoffContext.new(
          responsibility: request.responsibility,
          items: items
        )
      end

      private

      def project_visible_groups(manifest)
        groups = {}
        manifest.segments.each do |segment|
          policy_category = policy_category_for(segment)
          next unless policy_category

          key = selection_group_key(segment, policy_category)
          group = groups[key] ||= {
            policy_category: policy_category,
            segments: []
          }
          if group[:policy_category] != policy_category
            raise Phronomy::HandoffError,
              "one Handoff projection group spans incompatible policy categories"
          end
          group[:segments] << segment
        end
        groups
      end

      def policy_category_for(segment)
        explicit = segment.metadata["handoff_policy_category"] ||
          segment.metadata[:handoff_policy_category]
        return explicit.to_sym if explicit

        semantic_category =
          segment.metadata["context_policy_semantic_category"] ||
          segment.metadata[:context_policy_semantic_category]
        case semantic_category&.to_sym
        when :instruction
          return nil
        when :knowledge
          return :knowledge
        when :conversation
          return :current_request if segment.delivery.to_sym == :ask_argument
          return :history
        end

        return :current_request if segment.delivery.to_sym == :ask_argument
        return nil if CONTROL_CATEGORIES.include?(segment.category.to_sym)
        return :knowledge if segment.category.to_sym == :knowledge
        unit_kind = segment.metadata["selection_unit_kind"] ||
          segment.metadata[:selection_unit_kind]
        return :tool_exchanges if unit_kind.to_s == "tool_exchange"

        case segment.category.to_sym
        when :external_message, :assistant_message, :tool_message,
             :conversation, :memory, :summary, :structured_state
          :history
        end
      end

      def selection_group_key(segment, policy_category)
        conversation_group_id =
          segment.metadata["context_policy_conversation_group_id"] ||
          segment.metadata[:context_policy_conversation_group_id]
        if conversation_group_id
          return "context-policy-conversation:#{conversation_group_id}"
        end

        # Compatibility for finalized pre-ACS-04 manifests. New manifests use
        # context_policy_conversation_group_id and do not recreate Selection::Unit.
        unit_id = segment.metadata["selection_unit_id"] ||
          segment.metadata[:selection_unit_id]
        return "unit:#{unit_id}" if unit_id

        "segment:#{policy_category}:#{segment.position}"
      end

      def include_group?(request, category)
        policy = request.handoff.policy
        return true if policy.required?(category)
        return false if policy.forbidden?(category)

        request.selection_intent.fetch(category) do
          policy.default_include?(category)
        end
      end

      def materialize_item(segment, policy_category:, persistence:, source_agent:, target_agent:)
        bytes = persistence.contents.fetch(segment.content_ref)
        category = segment.category.to_sym
        metadata = segment.metadata.to_h.transform_keys(&:to_s)
        format = content_format_for(segment, metadata)
        content = (format == :json) ? Phronomy::CanonicalJSON.load(bytes) : bytes.to_s
        provenance = provenance_for(
          metadata,
          segment: segment,
          source_agent: source_agent,
          target_agent: target_agent
        )

        HandoffContext::Item.new(
          candidate_category: category,
          policy_category: policy_category,
          role: segment.role,
          content: content,
          content_format: format,
          tool_call_id: segment.tool_call_id,
          provenance: provenance,
          metadata: metadata.except(
            "context_policy_content_format",
            "context_policy_conversation_group_id",
            "selection_candidate_id", "selection_unit_id", "selection_unit_kind",
            "handoff_policy_category", "handoff_provenance"
          )
        )
      end

      def content_format_for(segment, metadata)
        explicit = metadata["context_policy_content_format"] ||
          metadata[:context_policy_content_format]
        if explicit
          format = explicit.to_sym
          unless Phronomy::Agent::ContextPolicyInput::CONTENT_FORMATS.include?(format)
            raise Phronomy::HandoffError,
              "unsupported Context content format in Manifest: #{explicit.inspect}"
          end
          return format
        end

        JSON_CATEGORIES.include?(segment.category.to_sym) ? :json : :text
      end

      def provenance_for(metadata, segment:, source_agent:, target_agent:)
        inherited = metadata["handoff_provenance"]
        if inherited
          base = HandoffContext::Provenance.new(
            origin_agent_id: inherited["origin_agent_id"] || inherited[:origin_agent_id],
            origin_record_id: inherited["origin_record_id"] || inherited[:origin_record_id],
            origin_execution_id: inherited["origin_execution_id"] || inherited[:origin_execution_id],
            origin_llm_call_id: inherited["origin_llm_call_id"] || inherited[:origin_llm_call_id],
            origin_tool_call_id: inherited["origin_tool_call_id"] || inherited[:origin_tool_call_id],
            transfer_path: inherited["transfer_path"] || inherited[:transfer_path]
          )
          return base.forwarded_to(target_agent.agent_id)
        end

        HandoffContext::Provenance.new(
          origin_agent_id: metadata["source_agent_id"] || source_agent.agent_id,
          origin_record_id: metadata["journal_record_id"],
          origin_execution_id: metadata["source_execution_id"],
          origin_llm_call_id: metadata["llm_call_id"],
          origin_tool_call_id: segment.tool_call_id,
          transfer_path: [source_agent.agent_id, target_agent.agent_id]
        )
      end
    end
  end
end
