# frozen_string_literal: true

module Phronomy
  module Agent
    # Base class for orchestrator agents that coordinate multiple subagents.
    # Implements the Orchestrator-Subagent multi-agent coordination pattern
    # (Anthropic blog, Pattern 2).
    #
    # @see https://claude.com/blog/multi-agent-coordination-patterns
    #
    # Extends {Phronomy::Agent::Base} with:
    # - A +subagent+ class-level DSL for declarative subagent registration. Each
    #   declared subagent is automatically exposed as an LLM-callable tool.
    # - +dispatch_parallel+ for programmatic parallel invocation of heterogeneous
    #   agents.
    # - +fan_out+ for parallel invocation of the same agent across multiple inputs.
    #
    # @example Declarative DSL
    #   class ResearchOrchestrator < Phronomy::Agent::Orchestrator
    #     model "gpt-4o"
    #     instructions "You coordinate research tasks."
    #     subagent :searcher,   SearchAgent
    #     subagent :summarizer, SummaryAgent
    #   end
    #
    #   result = ResearchOrchestrator.new.invoke("Research the latest AI news.")
    #
    # @example Programmatic parallel dispatch
    #   class MyOrchestrator < Phronomy::Agent::Orchestrator
    #     model "gpt-4o"
    #     instructions "Dispatch tasks in parallel."
    #
    #     def run(input)
    #       results = dispatch_parallel(
    #         { agent: SearchAgent,   input: "topic A" },
    #         { agent: AnalysisAgent, input: input }
    #       )
    #       results.map { |r| r[:output] }.join("\n")
    #     end
    #   end
    #
    # @example Fan-out (same agent, multiple inputs)
    #   results = fan_out(agent: TranslationAgent, inputs: ["Hello", "World"])
    class Orchestrator < Base
      # Declares a named subagent and registers it as a tool accessible to the
      # LLM during an +invoke+ call.
      #
      # Each call appends a new tool to this class's tool list.  The generated
      # tool's function name is +dispatch_to_<name>+.  When the LLM calls the
      # tool, a fresh instance of +agent_class+ is created and +invoke+ is called
      # with the provided input string.
      #
      # @param name        [Symbol] logical name that identifies the subagent
      # @param agent_class [Class]  subclass of {Phronomy::Agent::Base}
      # @param on_error    [Symbol] +:raise+ (default) re-raises any exception
      #   from the subagent; +:skip+ returns +nil+ so the LLM can decide how to
      #   proceed
      def self.subagent(name, agent_class, on_error: :raise)
        tool_class = Class.new(Phronomy::Tool::Base) do
          tool_name "dispatch_to_#{name}"
          description "Dispatch work to the #{name} subagent (#{agent_class.name})"
          param :input, type: :string, desc: "The task or question for the subagent"

          define_method(:execute) do |input:|
            result = agent_class.new.invoke(input)
            result[:output]
          rescue
            raise if on_error == :raise
            nil
          end
        end

        # Append without clobbering previously registered tools or aliases.
        @tools = (@tools || []) + [tool_class]
        @tool_aliases ||= {}

        registered_subagents[name] = {agent_class: agent_class, on_error: on_error}
      end

      # Returns the subagent registry for this specific class (not inherited).
      #
      # @return [Hash{Symbol => Hash}]
      def self.registered_subagents
        @registered_subagents ||= {}
      end

      # Dispatches multiple heterogeneous agent tasks in parallel using Ruby
      # threads. Each task is a Hash describing one agent invocation.
      #
      # Results are returned in the same order as the input +tasks+ array.
      # If any thread raises an exception, the exception is re-raised in the
      # calling thread after all threads have completed (via +Thread#value+).
      #
      # @param tasks [Array<Hash>]
      # @option task [Class]  :agent  agent class to invoke (required)
      # @option task [String] :input  input string for the agent (required)
      # @option task [Hash]   :config forwarded to +agent#invoke+ (default: +{}+)
      # @return [Array<Hash>] agent results in the same order as +tasks+
      def dispatch_parallel(*tasks)
        threads = tasks.map do |task|
          Thread.new do
            task[:agent].new.invoke(task[:input], config: task.fetch(:config, {}))
          end
        end
        threads.map(&:value)
      end

      # Runs the same agent against multiple inputs in parallel (fan-out pattern).
      #
      # @param agent  [Class]         agent class to invoke for every input
      # @param inputs [Array<String>] list of input strings
      # @param config [Hash]          forwarded to every +agent#invoke+ call
      # @return [Array<Hash>] results in the same order as +inputs+
      def fan_out(agent:, inputs:, config: {})
        dispatch_parallel(*inputs.map { |input| {agent: agent, input: input, config: config} })
      end
    end
  end
end
