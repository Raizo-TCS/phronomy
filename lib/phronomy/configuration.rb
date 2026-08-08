# frozen_string_literal: true

module Phronomy
  # Holds global configuration for the entire framework.
  # Configure via the Phronomy.configure block.
  #
  # @example
  #   Phronomy.configure do |config|
  #     config.default_model    = "claude-3-5-sonnet-20241022"
  #     config.recursion_limit  = 50
  #   end
  class Configuration
    STREAM_CALLBACK_ERROR_POLICIES = %i[report fail_task].freeze
    private_constant :STREAM_CALLBACK_ERROR_POLICIES

    # Default LLM model name (nil delegates to RubyLLM default)
    attr_accessor :default_model

    # Default embedding model name
    attr_accessor :default_embedding_model

    # Tracer instance
    attr_accessor :tracer

    # Global before_llm_input hook callable (Proc / lambda).
    # Called before every LLM request across all agents.
    # Receives a {Phronomy::Agent::LLMInputBuildContext}; must return a
    # {Phronomy::Agent::LLMInputPatch} or nil to pass through unchanged.
    attr_accessor :before_llm_input

    # Default output token reservation when an agent does not set max_output_tokens
    # and the model registry value equals the context window (making it unusable
    # as a per-request output reserve). Integer or nil.
    attr_accessor :default_output_reserve

    # Recursion limit for graph execution (default: 25)
    attr_accessor :recursion_limit

    # When true, agent LLM calls use {Phronomy::MultiAgent::ParallelToolChat}
    # for concurrent tool dispatch within a single agent turn.
    # Defaults to false.
    #
    # Previously, this was automatically enabled when +event_loop+ was true.
    # As of Phase 3, +parallel_tool_execution+ is a separate setting that must
    # be explicitly enabled.
    # @example
    #   Phronomy.configure { |c| c.parallel_tool_execution = true }
    # @return [Boolean]
    attr_accessor :parallel_tool_execution

    # When true, user input and LLM output are recorded in trace spans.
    # Defaults to false; set to true only in environments where PII capture is acceptable.
    # Set to false in privacy-sensitive environments to prevent PII from reaching
    # the tracing backend (OTel, Langfuse, etc.).
    attr_accessor :trace_pii

    # Optional logger for framework diagnostic messages (e.g. unreachable-state warnings).
    # Must respond to +#warn(message)+.  When nil (default), messages are written to +$stderr+
    # via +Kernel#warn+.
    # @example
    #   Phronomy.configure { |c| c.logger = Rails.logger }
    attr_accessor :logger

    # Grace period (in seconds) before the EventLoop background thread is force-killed
    # after a cooperative stop request.  Applies both to the overall thread join
    # and to the drain-and-cancel phase when +stop(drain: true)+ is used.
    # Default: 5 seconds.
    # @see Phronomy::EventLoop#stop
    attr_accessor :event_loop_stop_grace_seconds

    # Global state store for workflow persistence.
    # When set, WorkflowRunner routes all state reads and writes through this store.
    # Must be an instance of a class that inherits from Phronomy::StateStore::Base.
    # Defaults to +nil+ (no persistence — state lives only for the duration of invoke).
    # @example
    #   Phronomy.configure { |c| c.state_store = Phronomy::StateStore::InMemory.new }
    attr_accessor :state_store

    # Maximum byte length of a tool result returned to the LLM.
    # When a tool returns a String longer than this limit, the string is truncated
    # and a warning is logged.  Set to +nil+ (default) to disable truncation.
    # @example
    #   Phronomy.configure { |c| c.tool_result_max_size = 8192 }
    attr_accessor :tool_result_max_size

    # LLM adapter used by Agent::Base to perform LLM calls.
    # Must be an instance of a class that inherits from
    # {Phronomy::LLMAdapter::Base}.  Defaults to
    # {Phronomy::LLMAdapter::RubyLLM} which delegates to +chat.ask+ via
    # {BlockingAdapterPool}.
    # Set to a custom adapter to swap in an alternative LLM client without
    # changing any agent code.
    # @example
    #   Phronomy.configure { |c| c.llm_adapter = MyAsyncLLMAdapter.new }
    attr_accessor :llm_adapter

    # Set to +nil+ to disable the warning.
    # @return [Numeric, nil]
    attr_accessor :event_loop_starvation_threshold_seconds

    # Warn when processing a single event on the EventLoop thread takes longer
    # than this many seconds (long-running task / blocking-on-loop detection).
    # Set to +nil+ to disable the warning.
    # @return [Numeric, nil]
    attr_accessor :event_loop_dispatch_threshold_seconds

    # When true, enables all blocking operation diagnostics (Issue #279).
    # Equivalent to setting all diagnostic thresholds to their defaults.
    # @return [Boolean]
    attr_accessor :scheduler_debug

    # Wall-clock threshold (milliseconds) after which a task that has not
    # yielded the scheduler emits a warning log.  nil disables the check.
    # @return [Float, nil]
    attr_accessor :blocking_detect_threshold_ms

    # Determines how an unhandled Application exception from a terminal stream
    # callback affects the Task returned by Agent#stream_async or
    # Agent#approve_async.
    #
    # +:report+ logs the callback failure and preserves the Agent result.
    # +:fail_task+ logs the callback failure and fails the current Task with
    # {Phronomy::StreamCallbackError}. Neither policy terminates EventLoop.
    #
    # Default: +:report+.
    # @return [:report, :fail_task]
    attr_reader :stream_callback_error_policy

    # Number of OS worker threads in the default {BlockingAdapterPool}.
    # All LLM calls, MCP tool calls, and other blocking I/O share this pool.
    # Increase for higher LLM/tool throughput; decrease to limit
    # concurrency (e.g. to stay within a provider's rate limit).
    # Default: 10.
    # @return [Integer]
    attr_accessor :blocking_io_pool_size

    # Maximum number of operations that may wait in the {BlockingAdapterPool}
    # queue before {Phronomy::BackpressureError} is raised (on_full: :raise) or
    # the caller blocks (on_full: :wait, the default). Default: 100.
    # @return [Integer]
    attr_accessor :blocking_io_queue_size

    # Worker count for Tool authorization evaluation. The named pool is owned
    # by Runtime#pool(:authorization) and shares PoolRegistry lifecycle.
    # @return [Integer]
    attr_accessor :authorization_pool_size

    # Maximum queued Tool authorization evaluations.
    # @return [Integer]
    attr_accessor :authorization_queue_size

    # Operation-wide deadline for approval_facts, requires_approval callables,
    # and Agent#tool_approval_policy. Timeout fails closed to Human approval.
    # @return [Numeric]
    attr_accessor :authorization_timeout

    # Scheduler starvation threshold (milliseconds).
    # When a task waits more than this many milliseconds after calling
    # +runtime.yield+ before being resumed, the wait is counted as a starvation
    # event.  Used by the fairness regression test and by the
    # +tasks_waiting_over_threshold+ metric on {Phronomy::Runtime}.
    # Default: 50ms.
    # @return [Numeric]
    attr_accessor :starvation_threshold_ms

    # Scheduler backend to use for new {Phronomy::Runtime} instances.
    #
    # | Value | Scheduler | Typical use |
    # |-------|-----------|-------------|
    # | +:thread+ | {Runtime::ThreadScheduler} | **Default** — production-ready; one OS thread per task |
    # | +:immediate+ | {Runtime::FakeScheduler} | Tests — tasks run synchronously, no extra threads |
    # | +:fiber+ | {Runtime::DeterministicScheduler} (autorun) | **EXPERIMENTAL** — Fiber-based cooperative scheduler; do not use as production default |
    # | +:cooperative+ | {Runtime::FakeScheduler} | **Deprecated** — alias for +:immediate+; do not use in new code |
    #
    # The default is +:thread+. The +:fiber+ backend remains experimental and opt-in;
    # it will not become the default until integration test coverage is production grade
    # and virtual-time/timeout semantics are fully resolved (see Issues #350, #347, #348).
    #
    # When this setting is changed, the change only takes effect on the NEXT
    # call to {Runtime.instance} that auto-creates a new instance (i.e. after the
    # previous instance has been replaced or reset).  To replace the current
    # instance immediately call +Phronomy::Runtime.instance = nil+ first.
    #
    # @return [:thread, :immediate, :fiber]
    attr_accessor :runtime_backend

    # When +true+, calling {Agent#invoke} from inside a scheduler task
    # raises {SchedulerReentrancyError}.  When +false+ (default), a warning
    # is logged instead so that existing callers have time to migrate.
    # @return [Boolean]
    attr_accessor :strict_runtime_guards

    def stream_callback_error_policy=(value)
      unless STREAM_CALLBACK_ERROR_POLICIES.include?(value)
        allowed = STREAM_CALLBACK_ERROR_POLICIES.map(&:inspect).join(", ")
        raise Phronomy::ConfigurationError,
          "stream_callback_error_policy must be one of: #{allowed}"
      end

      @stream_callback_error_policy = value
    end

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
      @trace_pii = false
      @parallel_tool_execution = false
      @event_loop_stop_grace_seconds = 5
      @llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
      @event_loop_starvation_threshold_seconds = nil
      @event_loop_dispatch_threshold_seconds = nil
      @scheduler_debug = false
      @blocking_detect_threshold_ms = nil
      @stream_callback_error_policy = :report
      @blocking_io_pool_size = 10
      @blocking_io_queue_size = 100
      @authorization_pool_size = 4
      @authorization_queue_size = 100
      @authorization_timeout = 5
      @starvation_threshold_ms = 50
      @runtime_backend = :thread
      @strict_runtime_guards = false
    end
  end
end
