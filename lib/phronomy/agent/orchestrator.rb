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
      # Concurrency is bounded by +max_concurrency+; when nil all tasks run at
      # once (original behaviour).
      #
      # Error semantics are controlled by +on_error+:
      # - +:raise+ (default) — every task runs to completion; the first
      #   exception in input order is then re-raised in the calling thread.
      # - +:skip+            — failed tasks return +nil+; no exception is raised.
      #
      # @param tasks           [Array<Hash>]
      # @option task [Class]   :agent  agent class to invoke (required)
      # @option task [String]  :input  input string for the agent (required)
      # @option task [Hash]    :config forwarded to +agent#invoke+ (default: +{}+)
      # @param max_concurrency [Integer, nil] maximum number of concurrent threads;
      #   nil means no limit (all tasks run simultaneously)
      # @param on_error        [Symbol] +:raise+ or +:skip+
      # @return [Array<Hash, nil>] agent results in the same order as +tasks+
      # @raise [ArgumentError] if +on_error+ is not +:raise+ or +:skip+
      # @raise [ArgumentError] if +max_concurrency+ is not a positive Integer or nil
      def dispatch_parallel(*tasks, max_concurrency: nil, on_error: :raise)
        unless [:raise, :skip].include?(on_error)
          raise ArgumentError, "unknown on_error: #{on_error.inspect}"
        end
        unless max_concurrency.nil? || (max_concurrency.is_a?(Integer) && max_concurrency.positive?)
          raise ArgumentError, "max_concurrency must be a positive Integer"
        end

        bounded_map(tasks, max_concurrency: max_concurrency, on_error: on_error)
      end

      # Runs the same agent against multiple inputs in parallel (fan-out pattern).
      #
      # Accepts the same +max_concurrency:+ and +on_error:+ keyword arguments as
      # {#dispatch_parallel} and forwards them unchanged.
      #
      # @param agent           [Class]         agent class to invoke for every input
      # @param inputs          [Array<String>] list of input strings
      # @param config          [Hash]          forwarded to every +agent#invoke+ call
      # @param max_concurrency [Integer, nil]  forwarded to {#dispatch_parallel}
      # @param on_error        [Symbol]        forwarded to {#dispatch_parallel}
      # @return [Array<Hash, nil>] results in the same order as +inputs+
      def fan_out(agent:, inputs:, config: {}, max_concurrency: nil, on_error: :raise)
        dispatch_parallel(
          *inputs.map { |input| {agent: agent, input: input, config: config} },
          max_concurrency: max_concurrency,
          on_error: on_error
        )
      end

      private

      # Worker-pool implementation shared by {#dispatch_parallel} and {#fan_out}.
      #
      # Uses a +Queue+ as a work-stealing mechanism: each worker thread pops a
      # task, executes it, and loops until the queue is empty.  The number of
      # workers is +min(max_concurrency, tasks.length)+, capped at the task count
      # so we never spin up idle threads.
      #
      # +errors+ is indexed by task position so that the first error in *input*
      # order is deterministically re-raised when +on_error: :raise+ is used.
      # A +Mutex+ guards concurrent writes to +errors+ even though Array element
      # assignment at different indices is safe in MRI; this keeps the code
      # correct across alternative Ruby runtimes.
      def bounded_map(tasks, max_concurrency:, on_error:)
        return [] if tasks.empty?

        results      = Array.new(tasks.length)
        errors       = Array.new(tasks.length)
        errors_mutex = Mutex.new

        queue = Queue.new
        tasks.each_with_index { |task, i| queue << [i, task] }

        worker_count = [max_concurrency || tasks.length, tasks.length].min

        workers = worker_count.times.map do
          Thread.new do
            loop do
              i, task = begin
                queue.pop(true)
              rescue ThreadError
                break # queue is empty; this worker is done
              end

              begin
                results[i] = task[:agent].new.invoke(
                  task[:input],
                  config: task.fetch(:config, {})
                )
              rescue => e
                case on_error
                when :skip
                  results[i] = nil
                else
                  errors_mutex.synchronize { errors[i] = e }
                end
              end
            end
          end
        end

        workers.each(&:join)

        first_error = errors.compact.first
        raise first_error if first_error

        results
      end
    end
  end
end
