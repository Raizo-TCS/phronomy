# frozen_string_literal: true

module Phronomy
  module Agent
    # Value returned by a control capability after its domain policy is applied.
    # Agent validates exclusivity and Source ownership before accepting it.
    # @api public
    ControlRequest = Data.define(:target_agent_id, :responsibility, :selection, :llm_call_id, :tool_call_id) do
      def initialize(target_agent_id:, responsibility:, selection:, llm_call_id: nil, tool_call_id: nil)
        raise ArgumentError, "target_agent_id is required" if target_agent_id.to_s.empty?
        raise ArgumentError, "responsibility is required" if responsibility.to_s.strip.empty?
        normalized = selection.to_h.transform_keys(&:to_sym)
        unless normalized.values.all? { |value| value == true || value == false }
          raise ArgumentError, "context selection values must be boolean"
        end
        super(target_agent_id: target_agent_id.to_s.freeze, responsibility: responsibility.to_s.strip.freeze,
              selection: normalized.freeze, llm_call_id: llm_call_id&.to_s&.freeze, tool_call_id: tool_call_id&.to_s&.freeze)
      end
    end
  end
end
