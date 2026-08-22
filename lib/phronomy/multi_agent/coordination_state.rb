# frozen_string_literal: true

module Phronomy
  module MultiAgent
    CoordinationState = Data.define(:active_agent, :active_handoff_context) do
      def initialize(active_agent:, active_handoff_context: nil)
        unless active_agent.is_a?(Phronomy::Agent::Base)
          raise ArgumentError, "active_agent must be a Phronomy::Agent::Base"
        end
        if active_handoff_context && !active_handoff_context.is_a?(HandoffContext)
          raise ArgumentError, "active_handoff_context must be a HandoffContext"
        end
        super(
          active_agent: active_agent,
          active_handoff_context: active_handoff_context
        )
        freeze
      end
    end
  end
end
