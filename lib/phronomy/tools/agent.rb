# frozen_string_literal: true

module Phronomy
  module Tools
    # Wraps a Phronomy::Agent::Base subclass as a callable tool so that a parent
    # agent can delegate a one-shot sub-task through the same stateful pipeline.
    class Agent < Phronomy::Agent::Context::Capability::Base
      description "Wraps an agent as a tool"
      param :input, type: :string, desc: "The input to forward to the wrapped agent"

      class << self
        def from_agent(agent_class, tool_name: nil, description: nil)
          raise ArgumentError, "agent_class must be a Class" unless agent_class.is_a?(Class)
          unless agent_class <= Phronomy::Agent::Base
            raise ArgumentError,
              "agent_class must inherit from Phronomy::Agent::Base"
          end

          # Fail at Tool definition time rather than on the first Tool call.
          agent_class.agent_definition

          klass = Class.new(self)
          effective_name = tool_name || derive_name(agent_class)
          effective_desc = description || "Delegates to #{agent_class.name || "an agent"}"

          klass.tool_name(effective_name)
          klass.description(effective_desc)
          klass.define_method(:execute) do |input:|
            result = Phronomy::Agent.run_once(
              definition: agent_class,
              input: input
            )
            result[:output].to_s
          end
          klass
        end

        private

        def derive_name(agent_class)
          return "agent_tool" unless agent_class.name

          agent_class.name
            .split("::").last
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
            .gsub(/([a-z\\d])([A-Z])/, '\\1_\\2')
            .downcase
            .sub(/_agent$/, "")
            .sub(/_tool$/, "")
        end
      end
    end
  end
end
