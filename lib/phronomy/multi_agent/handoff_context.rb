# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class HandoffContext
      Provenance = Data.define(
        :origin_agent_id,
        :origin_record_id,
        :origin_execution_id,
        :origin_llm_call_id,
        :origin_tool_call_id,
        :transfer_path
      ) do
        def initialize(**values)
          super(**values.merge(
            origin_agent_id: values[:origin_agent_id]&.to_s&.freeze,
            origin_record_id: values[:origin_record_id]&.to_s&.freeze,
            origin_execution_id: values[:origin_execution_id]&.to_s&.freeze,
            origin_llm_call_id: values[:origin_llm_call_id]&.to_s&.freeze,
            origin_tool_call_id: values[:origin_tool_call_id]&.to_s&.freeze,
            transfer_path: Array(values[:transfer_path]).map(&:to_s).freeze
          ))
          freeze
        end

        def forwarded_to(agent_id)
          self.class.new(
            origin_agent_id: origin_agent_id,
            origin_record_id: origin_record_id,
            origin_execution_id: origin_execution_id,
            origin_llm_call_id: origin_llm_call_id,
            origin_tool_call_id: origin_tool_call_id,
            transfer_path: transfer_path + [agent_id.to_s]
          )
        end

        def to_h
          {
            "origin_agent_id" => origin_agent_id,
            "origin_record_id" => origin_record_id,
            "origin_execution_id" => origin_execution_id,
            "origin_llm_call_id" => origin_llm_call_id,
            "origin_tool_call_id" => origin_tool_call_id,
            "transfer_path" => transfer_path
          }.compact.freeze
        end
      end

      Item = Data.define(
        :candidate_category,
        :policy_category,
        :role,
        :content,
        :content_format,
        :tool_call_id,
        :provenance,
        :metadata
      ) do
        def initialize(**values)
          provenance = values.fetch(:provenance)
          unless provenance.is_a?(Provenance)
            raise ArgumentError, "HandoffContext::Item provenance must be Provenance"
          end
          format = (values[:content_format] || :text).to_sym
          unless %i[text json].include?(format)
            raise ArgumentError, "unsupported Handoff Context content format: #{format.inspect}"
          end
          super(**values.merge(
            candidate_category: values.fetch(:candidate_category).to_sym,
            policy_category: values.fetch(:policy_category).to_sym,
            role: values[:role]&.to_sym,
            content: Immutable.copy(values.fetch(:content)),
            content_format: format,
            tool_call_id: values[:tool_call_id]&.to_s&.freeze,
            provenance: provenance,
            metadata: Immutable.copy(values[:metadata] || {})
          ))
          freeze
        end
      end

      attr_reader :responsibility, :items

      def initialize(responsibility:, items: [])
        @responsibility = responsibility.to_s.freeze
        @items = Array(items).freeze
        raise ArgumentError, "Handoff Context responsibility must not be empty" if @responsibility.strip.empty?
        unless @items.all? { |item| item.is_a?(Item) }
          raise ArgumentError, "Handoff Context items must be HandoffContext::Item values"
        end
        freeze
      end
    end
  end
end
