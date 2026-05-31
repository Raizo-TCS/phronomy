# frozen_string_literal: true

require "securerandom"

module Phronomy
  module MultiAgent
    # Represents a transfer edge from one agent to another.
    # Creates an anonymous Phronomy::Agent::Context::Capability::Base subclass that the source agent
    # exposes to the LLM as a +transfer_to_<name>+ function.
    # The tool's execute method returns a sentinel string that Runner uses to
    # detect which target agent to route to next.
    #
    # @example
    #   billing = BillingAgent.new
    #   handoff = Phronomy::MultiAgent::Handoff.new(target_agent: billing)
    #   tool_class = handoff.to_tool_class
    class Handoff
      # Prefix embedded in tool results so Runner can detect handoffs.
      SENTINEL_PREFIX = "__PHRONOMY_HANDOFF__"

      attr_reader :target_agent, :tool_name, :description

      # @param target_agent [Phronomy::Agent::Base] the agent to hand off to
      # @param description  [String, nil] overrides the auto-generated tool description
      # @api public
      def initialize(target_agent:, description: nil)
        @target_agent = target_agent
        klass_name = target_agent.class.name&.split("::")&.last || "Agent"
        # Use a UUID so that two handoffs targeting the same class remain distinct.
        @uuid = SecureRandom.uuid
        @tool_name = "transfer_to_#{snake_case(klass_name)}_#{@uuid.delete("-")[0, 8]}"
        @description = description || "Transfer the conversation to #{klass_name}."
      end

      # Builds an anonymous Phronomy::Agent::Context::Capability::Base subclass for this handoff.
      # @return [Class<Phronomy::Agent::Context::Capability::Base>]
      # @api public
      def to_tool_class
        sentinel_value = sentinel
        tn = tool_name
        desc = description
        Class.new(Phronomy::Agent::Context::Capability::Base) do
          tool_name tn
          description desc
          define_method(:execute) { sentinel_value }
        end
      end

      # The sentinel string embedded in the tool result.
      # @return [String]
      # @api public
      def sentinel
        "#{SENTINEL_PREFIX}:#{target_agent.class.name}:#{@uuid}"
      end

      private

      def snake_case(klass_name)
        klass_name.gsub(/([A-Z])/) { "_#{$1}" }.downcase.delete_prefix("_")
      end
    end
  end
end
