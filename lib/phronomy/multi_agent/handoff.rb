# frozen_string_literal: true

require "securerandom"

module Phronomy
  module MultiAgent
    # Application-defined semantic edge for transferring active responsibility
    # from one live Agent instance to another.
    class Handoff
      attr_reader :source_agent, :target_agent, :policy, :description

      # @api public
      def initialize(source_agent:, target_agent:, policy: HandoffPolicy.default, description: nil)
        unless source_agent.is_a?(Phronomy::Agent::Base) &&
            target_agent.is_a?(Phronomy::Agent::Base)
          raise ArgumentError, "source_agent and target_agent must be Agent::Base instances"
        end
        if source_agent.equal?(target_agent)
          raise ArgumentError, "Handoff source_agent and target_agent must be different instances"
        end
        unless policy.is_a?(HandoffPolicy)
          raise ArgumentError, "policy must be a Phronomy::MultiAgent::HandoffPolicy"
        end

        @source_agent = source_agent
        @target_agent = target_agent
        @policy = policy
        @description = (description || default_description).to_s.freeze
        @transport_key = SecureRandom.hex(8).freeze
        freeze
      end

      private

      attr_reader :transport_key

      def default_description
        target_name = target_agent.class.name || "target Agent"
        "Transfer active responsibility to #{target_name}."
      end
    end
  end
end
