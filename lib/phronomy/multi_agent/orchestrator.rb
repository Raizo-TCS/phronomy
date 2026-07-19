# frozen_string_literal: true

module Phronomy
  module MultiAgent
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
    #   class ResearchOrchestrator < Phronomy::MultiAgent::Orchestrator
    #     model "gpt-4o"
    #     instructions "You coordinate research tasks."
    #     subagent :searcher,   SearchAgent
    #     subagent :summarizer, SummaryAgent
    #   end
    #
    #   result = ResearchOrchestrator.new.invoke("Research the latest AI news.")
    #
    # @example Programmatic parallel dispatch
    #   class MyOrchestrator < Phronomy::MultiAgent::Orchestrator
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
    class Orchestrator < Agent::Base
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
      # @api public
      def self.subagent(name, agent_class, on_error: :raise)
        tool_class = Class.new(Phronomy::Agent::Context::Capability::Base) do
          tool_name "dispatch_to_#{name}"
          description "Dispatch work to the #{name} subagent (#{agent_class.name})"
          param :input, type: :string, desc: "The task or question for the subagent"

          # @_orchestrator_context is injected at call time by prepare_tool_class.
          attr_writer :_orchestrator_context

          define_method(:execute) do |input:|
            # Inherit the calling orchestrator's thread_id, config, and
            # InvocationContext so that child subagent spans and memory stay
            # connected to the parent invocation.
            ctx = @_orchestrator_context || {}
            parent_ic = ctx[:invocation_context]
            task_config = ctx[:config] || {}

            # Propagate parent InvocationContext to the child agent so that
            # cancellation, deadline, and tracing carry through automatically.
            if parent_ic && !task_config[:invocation_context]
              child_ic = parent_ic.merge(parent_task_id: parent_ic.task_id)
              task_config = task_config.merge(invocation_context: child_ic)
            end

            result = agent_class.new.invoke_async(
              input,
              thread_id: ctx[:thread_id] || parent_ic&.thread_id,
              config: task_config
            ).wait_result
            result[:output]
          rescue
            raise if on_error == :raise
            nil
          end
        end

        # Track this tool class so prepare_tool_class can inject context.
        @_subagent_tool_classes = (@_subagent_tool_classes || []) + [tool_class]

        # Append without clobbering previously registered tools or aliases.
        @tools = (@tools || []) + [tool_class]
        @tool_aliases ||= {}

        registered_subagents[name] = {agent_class: agent_class, on_error: on_error}
      end

      # Returns the subagent tool classes registered on this specific class.
      # Used by {#prepare_tool_class} to inject context.
      # @return [Array<Class>]
      # @api private
      def self._subagent_tool_classes
        @_subagent_tool_classes || []
      end

      # Returns the subagent registry for this specific class (not inherited).
      #
      # @return [Hash{Symbol => Hash}]
      # @api public
      def self.registered_subagents
        @registered_subagents ||= {}
      end

      # Dispatches multiple heterogeneous agent tasks in parallel using
      # cooperative {Task}s. Each task is a Hash describing one agent invocation.
      #
      # Results are returned in the same order as the input +tasks+ array.
      # Concurrency is bounded by +max_concurrency+; when nil all tasks run at
      # once (original behaviour).
      #
      # Error semantics are controlled by +on_error+:
      # - +:raise+ (default) — every task runs to completion; the first
      #   exception in input order is then re-raised in the calling task.
      # - +:skip+            — failed tasks return +nil+; no exception is raised.
      #
      # @param tasks           [Array<Hash>]
      # @option task [Class]   :agent  agent class to invoke (required)
      # @option task [String]  :input  input string for the agent (required)
      # @option task [Hash]    :config forwarded to +agent#invoke+ (default: +{}+)
      # @option task [String]  :thread_id forwarded to +agent#invoke+ (default: nil)
      # @param max_concurrency    [Integer, nil] maximum number of concurrent tasks;
      #   nil means no limit (all tasks run simultaneously)
      # @param on_error            [Symbol] +:raise+ or +:skip+
      # @param timeout             [Numeric, nil] maximum seconds to wait for all tasks;
      #   nil means wait indefinitely. When the deadline is exceeded,
      #   {Phronomy::TimeoutError} is raised and all surviving tasks are cancelled
      #   cooperatively.
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] when provided, the
      #   token is merged into each task's config (unless the task already sets one) so
      #   that every child agent checks it before making LLM calls.
      # @param invocation_context [Phronomy::InvocationContext, nil] when provided,
      #   the context (cancellation_token, deadline, thread_id) is propagated to each
      #   child agent as a child InvocationContext.
      # @param force_kill [Boolean] deprecated — cooperative cancellation is always
      #   used; this parameter is accepted for backwards compatibility but has no effect.
      # @return [Array<Hash, nil>] agent results in the same order as +tasks+
      # @raise [ArgumentError] if +on_error+ is not +:raise+ or +:skip+
      # @raise [ArgumentError] if +max_concurrency+ is not a positive Integer or nil
      # @raise [Phronomy::TimeoutError] if +timeout+ is exceeded
      # @api public
      def dispatch_parallel(*tasks, max_concurrency: nil, on_error: :raise, timeout: nil, cancellation_token: nil, invocation_context: nil, force_kill: false)
        unless [:raise, :skip].include?(on_error)
          raise ArgumentError, "unknown on_error: #{on_error.inspect}"
        end
        if max_concurrency && !(max_concurrency.is_a?(Integer) && max_concurrency.positive?)
          raise ArgumentError, "max_concurrency must be a positive Integer"
        end

        bounded_map(tasks, max_concurrency: max_concurrency, on_error: on_error, timeout: timeout, cancellation_token: cancellation_token, invocation_context: invocation_context, force_kill: force_kill)
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
      # @param max_concurrency    [Integer, nil]  forwarded to {#dispatch_parallel}
      # @param on_error            [Symbol]        forwarded to {#dispatch_parallel}
      # @param invocation_context [Phronomy::InvocationContext, nil] forwarded to
      #   {#dispatch_parallel} for child context propagation
      # @return [Array<Hash, nil>] results in the same order as +inputs+
      # @api public
      def fan_out(agent:, inputs:, config: {}, thread_id: nil, max_concurrency: nil, on_error: :raise, timeout: nil, cancellation_token: nil, invocation_context: nil, force_kill: false)
        dispatch_parallel(
          *inputs.map { |input| {agent: agent, input: input, config: config, thread_id: thread_id} },
          max_concurrency: max_concurrency,
          on_error: on_error,
          timeout: timeout,
          cancellation_token: cancellation_token,
          invocation_context: invocation_context,
          force_kill: force_kill
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
      # @api public
      def subagent(agent_class, input, config: nil, thread_id: nil)
        ctx = @_orchestrator_context || {}
        parent_ic = ctx[:invocation_context]
        effective_config = config || ctx[:config] || {}

        # Propagate parent InvocationContext to the child agent.
        if parent_ic && !effective_config[:invocation_context]
          child_ic = parent_ic.merge(parent_task_id: parent_ic.task_id)
          effective_config = effective_config.merge(invocation_context: child_ic)
        end

        agent_class.new.invoke_async(
          input,
          config: effective_config,
          thread_id: thread_id || ctx[:thread_id] || parent_ic&.thread_id
        ).wait_result
      end

      private

      # Override invoke_once to expose the current thread_id and config via an
      # instance variable so that DSL-registered subagent tools can inherit them
      # without using Thread.current.
      def invoke_once(input, messages: [], thread_id: nil, config: {})
        prev = @_orchestrator_context
        @_orchestrator_context = {
          thread_id: thread_id,
          config: config,
          invocation_context: config[:invocation_context]
        }
        super
      ensure
        @_orchestrator_context = prev
      end

      # Override prepare_tool_class to inject the current orchestrator context
      # into DSL-registered subagent tools before each call.
      def prepare_tool_class(tool_class)
        prepared = super
        orch = self

        # Only wrap subagent tools (those registered via the .subagent DSL).
        return prepared unless self.class._subagent_tool_classes.include?(tool_class)

        # Capture the effective tool name before building the anonymous subclass.
        # Class-level instance variables (@tool_name) are not inherited through
        # subclassing, so the wrapper must set it explicitly.
        effective_name = prepared.new.name
        Class.new(prepared) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            self._orchestrator_context = orch.instance_variable_get(:@_orchestrator_context)
            super(args, **kwargs)
          end
        end
      end

      # Task-based worker pool shared by {#dispatch_parallel} and {#fan_out}.
      #
      # Spawns one {Task} per input using a {TaskGroup} so that +max_concurrency+
      # acts as a semaphore: spare tasks block on {TaskGroup#spawn} until a slot
      # becomes available.  Results are written back to +results+ in input order;
      # +errors+ captures the first error per position so that the first error in
      # *input* order is deterministically re-raised when +on_error: :raise+ is used.
      #
      # When +timeout+ is given, each spawned task is joined with the remaining
      # deadline.  Any still-alive tasks are cancelled cooperatively via
      # {TaskGroup#cancel_all!} before {Phronomy::TimeoutError} is raised.
      # The +force_kill+ argument is deprecated: cooperative cancellation is always
      # used regardless of its value.
      #
      # Deadline tracking uses +Process.clock_gettime(Process::CLOCK_MONOTONIC)+
      # to avoid sensitivity to NTP adjustments and system-clock changes.
      def bounded_map(tasks, max_concurrency:, on_error:, timeout: nil, cancellation_token: nil, invocation_context: nil, force_kill: false) # rubocop:disable Lint/UnusedMethodArgument
        return [] if tasks.empty?

        results = Array.new(tasks.length)
        errors = Array.new(tasks.length)
        group = Phronomy::Runtime.instance.task_group(limit: max_concurrency || tasks.length)

        # Resolve the effective cancellation token: explicit argument wins;
        # fall back to the one embedded in the InvocationContext if present.
        effective_ct = cancellation_token || invocation_context&.cancellation_token

        spawned = tasks.each_with_index.map do |task, i|
          group.spawn do
            task_config = task.fetch(:config, {})

            # Merge the shared cancellation token unless the task already has one.
            if effective_ct && !task_config[:cancellation_token]
              task_config = task_config.merge(cancellation_token: effective_ct)
            end

            # Propagate parent InvocationContext to each child task so that
            # cancellation, deadline, and tracing carry through automatically.
            if invocation_context && !task_config[:invocation_context]
              child_ic = invocation_context.merge(parent_task_id: invocation_context.task_id)
              task_config = task_config.merge(invocation_context: child_ic)
            end

            results[i] = task[:agent].new.invoke_async(
              task[:input],
              config: task_config,
              thread_id: task[:thread_id] || invocation_context&.thread_id
            ).wait_result
          rescue => e
            errors[i] = e unless on_error == :skip
          end
        end

        if timeout
          deadline = Phronomy::Concurrency::Deadline.in(timeout)
          spawned.each { |t| t.join([deadline.remaining_seconds, 0].max) }

          alive = spawned.select(&:alive?)
          unless alive.empty?
            group.cancel_all!
            raise Phronomy::TimeoutError,
              "dispatch_parallel timed out after #{timeout}s " \
              "(#{alive.length} of #{spawned.length} tasks still running)"
          end
        else
          spawned.each(&:wait_result)
        end

        first_error = errors.compact.first
        raise first_error if first_error

        results
      end
    end
  end
end
