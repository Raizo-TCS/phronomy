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
            # Inherit the calling orchestrator's thread_id and config when
            # available so that sub-agent spans and memory stay connected.
            ctx = Thread.current[:phronomy_orchestrator_context] || {}
            result = agent_class.new.invoke(
              input,
              thread_id: ctx[:thread_id],
              config: ctx[:config] || {}
            )
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
      # @option task [String]  :thread_id forwarded to +agent#invoke+ (default: nil)
      # @param max_concurrency    [Integer, nil] maximum number of concurrent threads;
      #   nil means no limit (all tasks run simultaneously)
      # @param on_error            [Symbol] +:raise+ or +:skip+
      # @param timeout             [Numeric, nil] maximum seconds to wait for all workers;
      #   nil means wait indefinitely. When the deadline is exceeded,
      #   {Phronomy::TimeoutError} is raised and all surviving worker threads are killed.
      # @param cancellation_token [Phronomy::CancellationToken, nil] when provided, the
      #   token is merged into each task's config (unless the task already sets one) so
      #   that every worker agent checks it before making LLM calls.
      # @return [Array<Hash, nil>] agent results in the same order as +tasks+
      # @raise [ArgumentError] if +on_error+ is not +:raise+ or +:skip+
      # @raise [ArgumentError] if +max_concurrency+ is not a positive Integer or nil
      # @raise [Phronomy::TimeoutError] if +timeout+ is exceeded
      def dispatch_parallel(*tasks, max_concurrency: nil, on_error: :raise, timeout: nil, cancellation_token: nil)
        unless [:raise, :skip].include?(on_error)
          raise ArgumentError, "unknown on_error: #{on_error.inspect}"
        end
        if max_concurrency && !(max_concurrency.is_a?(Integer) && max_concurrency.positive?)
          raise ArgumentError, "max_concurrency must be a positive Integer"
        end

        bounded_map(tasks, max_concurrency: max_concurrency, on_error: on_error, timeout: timeout, cancellation_token: cancellation_token)
      end

      # Runs the same agent against multiple inputs in parallel (fan-out pattern).
      #
      # Accepts the same +max_concurrency:+ and +on_error:+ keyword arguments as
      # {#dispatch_parallel} and forwards them unchanged.
      #
      # @param agent           [Class]         agent class to invoke for every input
      # @param inputs          [Array<String>] list of input strings
      # @param config          [Hash]          forwarded to every +agent#invoke+ call
      # @param thread_id       [String, nil]   forwarded to every +agent#invoke+ call
      # @param max_concurrency [Integer, nil]  forwarded to {#dispatch_parallel}
      # @param on_error        [Symbol]        forwarded to {#dispatch_parallel}
      # @return [Array<Hash, nil>] results in the same order as +inputs+
      def fan_out(agent:, inputs:, config: {}, thread_id: nil, max_concurrency: nil, on_error: :raise, timeout: nil, cancellation_token: nil)
        dispatch_parallel(
          *inputs.map { |input| {agent: agent, input: input, config: config, thread_id: thread_id} },
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token
        )
      end

      # Programmatically dispatches a single sub-agent from inside an orchestrator
      # instance, inheriting the parent's +thread_id+ and +config+ by default.
      #
      # @param agent_class [Class]         subclass of {Phronomy::Agent::Base}
      # @param input       [String]        task or question for the sub-agent
      # @param config      [Hash, nil]     override config (falls back to parent's)
      # @param thread_id   [String, nil]   override thread_id (falls back to parent's)
      # @return [Hash]  the sub-agent's result hash (+:output+, +:messages+)
      def subagent(agent_class, input, config: nil, thread_id: nil)
        ctx = Thread.current[:phronomy_orchestrator_context] || {}
        agent_class.new.invoke(
          input,
          config: config || ctx[:config] || {},
          thread_id: thread_id || ctx[:thread_id]
        )
      end

      private

      # Override invoke_once to expose the current thread_id and config via a
      # thread-local so that DSL-registered subagent tools can inherit them.
      def invoke_once(input, messages: [], thread_id: nil, config: {})
        prev = Thread.current[:phronomy_orchestrator_context]
        Thread.current[:phronomy_orchestrator_context] = {thread_id: thread_id, config: config}
        super
      ensure
        Thread.current[:phronomy_orchestrator_context] = prev
      end

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
      #
      # When +timeout+ is given, workers are first asked to stop cooperatively
      # via a cancellation flag (so they do not pick up new tasks) and then given
      # +KILL_GRACE_SECONDS+ to finish any in-flight +ensure+ blocks.  Only
      # workers that are still alive after the grace period are force-killed, and
      # a warning is logged in that case.  Use a +CancellationToken+ (see #216)
      # for full cooperative cancellation of long-running tasks.
      #
      # Deadline tracking uses +Process.clock_gettime(Process::CLOCK_MONOTONIC)+
      # to avoid sensitivity to NTP adjustments and system-clock changes.
      KILL_GRACE_SECONDS = 0.5
      private_constant :KILL_GRACE_SECONDS

      def bounded_map(tasks, max_concurrency:, on_error:, timeout: nil, cancellation_token: nil)
        return [] if tasks.empty?

        results = Array.new(tasks.length)
        errors = Array.new(tasks.length)
        errors_mutex = Mutex.new
        # Mutex-backed cooperative stop token; workers check before each task pick-up.
        internal_stop_token = Phronomy::CancellationToken.new

        queue = Queue.new
        tasks.each_with_index { |task, i| queue << [i, task] }

        worker_count = [max_concurrency || tasks.length, tasks.length].min

        workers = worker_count.times.map do
          Thread.new do
            loop do
              break if internal_stop_token.cancelled?

              i, task = begin
                queue.pop(true)
              rescue ThreadError
                break # queue is empty; this worker is done
              end

              # Merge the shared cancellation token into the task's config unless
              # the task already supplies its own token.
              task_config = task.fetch(:config, {})
              if cancellation_token && !task_config[:cancellation_token]
                task_config = task_config.merge(cancellation_token: cancellation_token)
              end

              begin
                results[i] = task[:agent].new.invoke(
                  task[:input],
                  config: task_config,
                  thread_id: task[:thread_id]
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

        workers.each(&:join) if timeout.nil?

        if timeout
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
          workers.each do |w|
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            w.join([remaining, 0].max)
          end

          alive = workers.select(&:alive?)
          unless alive.empty?
            # Signal workers cooperatively to stop picking up new tasks.
            internal_stop_token.cancel!
            # Give in-flight ensure blocks a short grace period before kill.
            alive.each { |w| w.join(KILL_GRACE_SECONDS) }
            still_alive = alive.select(&:alive?)
            if still_alive.any?
              Phronomy.configuration.logger&.warn(
                "[Phronomy] dispatch_parallel: #{still_alive.length} worker(s) did not stop " \
                "within grace period; force-killing. Use CancellationToken (#216) for " \
                "cooperative cancellation of long-running tasks."
              )
              still_alive.each(&:kill)
            end
            raise Phronomy::TimeoutError,
              "dispatch_parallel timed out after #{timeout}s " \
              "(#{alive.length} of #{workers.length} workers still running)"
          end
        end

        first_error = errors.compact.first
        raise first_error if first_error

        results
      end
    end
  end
end
