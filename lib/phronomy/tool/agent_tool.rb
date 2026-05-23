# frozen_string_literal: true

module Phronomy
  module Tool
    # Wraps a Phronomy::Agent::Base subclass as a callable tool so that a parent
    # ReactAgent (or any agent that supports tools) can delegate sub-tasks to a
    # fully-capable agent.
    #
    # Use AgentTool.from_agent to generate a concrete tool class.  The generated
    # class is anonymous; assign it to a constant when you need a stable name.
    #
    # @example Wrap an existing agent
    #   SummarizerTool = Phronomy::Tool::AgentTool.from_agent(
    #     SummarizerAgent,
    #     tool_name:   "summarize",
    #     description: "Summarizes a long text and returns a brief summary"
    #   )
    #
    #   class OrchestratorAgent < Phronomy::Agent::ReactAgent
    #     model "openai/gpt-4o-mini"
    #     instructions "You are an orchestrator that delegates to specialist agents."
    #     tools SummarizerTool
    #   end
    class AgentTool < Phronomy::Tool::Base
      description "Wraps an agent as a tool"
      param :input, type: :string, desc: "The input to forward to the wrapped agent"

      class << self
        # Generates a Phronomy::Tool::AgentTool subclass that delegates #execute to
        # an instance of +agent_class+.
        #
        # @param agent_class  [Class] a Phronomy::Agent::Base subclass
        # @param tool_name    [String, nil] function name exposed to the LLM;
        #   defaults to a snake_case derivation of the agent class name
        # @param description  [String, nil] description exposed to the LLM;
        #   defaults to "Delegates to <AgentClassName>"
        # @return [Class] an anonymous Phronomy::Tool::AgentTool subclass
        # @api public
        def from_agent(agent_class, tool_name: nil, description: nil)
          raise ArgumentError, "agent_class must be a Class" unless agent_class.is_a?(Class)

          klass = Class.new(self)

          effective_name = tool_name || derive_name(agent_class)
          effective_desc = description || "Delegates to #{agent_class.name || "an agent"}"

          klass.tool_name(effective_name)
          klass.description(effective_desc)

          klass.define_method(:execute) do |input:|
            result = agent_class.new.invoke(input)
            result[:output].to_s
          end

          klass
        end

        private

        # Derives a snake_case tool name from the agent class name.
        # e.g. "My::SummarizerAgent" → "summarizer"
        #      "TranslatorAgent"     → "translator"
        def derive_name(agent_class)
          return "agent_tool" unless agent_class.name

          agent_class.name
            .split("::").last
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
            .sub(/_agent$/, "")
            .sub(/_tool$/, "")
        end
      end
    end
  end
end
