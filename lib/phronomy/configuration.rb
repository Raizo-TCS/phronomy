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
    # Default LLM model name (nil delegates to RubyLLM default)
    attr_accessor :default_model

    # Default embedding model name
    attr_accessor :default_embedding_model

    # Tracer instance
    attr_accessor :tracer

    # Global before_completion hook callable (Proc / lambda).
    # Called before every LLM request across all agents.
    # Receives a {Phronomy::Agent::BeforeCompletionContext}; must return a Hash
    # of params to merge, or nil to pass through unchanged.
    attr_accessor :before_completion

    # Recursion limit for graph execution (default: 25)
    attr_accessor :recursion_limit

    # When true, workflow execution is driven by EventLoop instead of a
    # synchronous loop in the calling thread. Defaults to false (sync mode).
    # @see Phronomy::EventLoop
    attr_accessor :event_loop

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

    # Default backpressure strategy for {BlockingAdapterPool#submit} when the
    # queue is full.  One of +:wait+ (block until a slot is available),
    # +:raise+ (raise {Phronomy::BackpressureError}), or +:timeout+ (raise
    # {Phronomy::TimeoutError} after +backpressure_timeout+ seconds).
    # @return [:wait, :raise, :timeout]
    attr_accessor :backpressure

    # Seconds to wait before raising {Phronomy::TimeoutError} when
    # +backpressure+ is +:timeout+.
    # @return [Numeric, nil]
    attr_accessor :backpressure_timeout

    # Warn when an event spends longer than this many seconds waiting in the
    # EventLoop queue before being dispatched (starvation detection).
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

    # Maximum number of concurrent agent tasks (invoke_async calls in-flight).
    # nil = unlimited (default).  When at capacity, behaviour is controlled by
    # +backpressure+ (:wait, :raise/:reject, :timeout).
    # @return [Integer, nil]
    attr_accessor :max_concurrent_agent_tasks

    # Maximum number of concurrent tool tasks (parallel tool calls in-flight).
    # nil = unlimited (default).
    # @return [Integer, nil]
    attr_accessor :max_concurrent_tool_tasks

    # Maximum number of concurrent workflow tasks.
    # nil = unlimited (default).
    # @return [Integer, nil]
    attr_accessor :max_concurrent_workflow_tasks

    # Maximum number of concurrent LLM calls in-flight.
    # nil = unlimited (default).
    # @return [Integer, nil]
    attr_accessor :max_concurrent_llm_calls

    # Upper bound on the number of streaming token chunks that may be buffered
    # in the {AsyncQueue} used by {Agent#stream} before the LLM producer is
    # throttled.  When nil (default), the queue is unbounded.
    # @return [Integer, nil]
    attr_accessor :stream_queue_max_size

    # Maximum number of concurrent RAG knowledge-source fetches in-flight.
    # nil = unlimited (default).
    # @return [Integer, nil]
    attr_accessor :max_concurrent_rag_fetches

    # Maximum number of concurrent vector-store searches in-flight.
    # nil = unlimited (default).
    # @return [Integer, nil]
    attr_accessor :max_concurrent_vector_searches

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
    # | +:thread+ | {Runtime::ThreadScheduler} | Default — one OS thread per task |
    # | +:immediate+ | {Runtime::FakeScheduler} | Tests — tasks run synchronously, no extra threads |
    # | +:cooperative+ | {Runtime::FakeScheduler} | Deprecated alias for +:immediate+ |
    # | +:fiber+ | {Runtime::DeterministicScheduler} (autorun) | EXPERIMENTAL Fiber-based cooperative scheduler |
    #
    # When this setting is changed, the change only takes effect on the NEXT
    # call to {Runtime.instance} that auto-creates a new instance (i.e. after the
    # previous instance has been replaced or reset).  To replace the current
    # instance immediately call +Phronomy::Runtime.instance = nil+ first.
    #
    # @return [:thread, :immediate, :cooperative, :fiber]
    attr_accessor :runtime_backend

    # When +true+, calling {Agent#invoke} from inside a scheduler task
    # raises {SchedulerReentrancyError}.  When +false+ (default), a warning
    # is logged instead so that existing callers have time to migrate.
    # @return [Boolean]
    attr_accessor :strict_runtime_guards

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
      @trace_pii = false
      @event_loop = false
      @event_loop_stop_grace_seconds = 5
      @llm_adapter = Phronomy::LLMAdapter::RubyLLM.new
      @backpressure = :wait
      @backpressure_timeout = nil
      @event_loop_starvation_threshold_seconds = nil
      @event_loop_dispatch_threshold_seconds = nil
      @scheduler_debug = false
      @blocking_detect_threshold_ms = nil
      @max_concurrent_agent_tasks = nil
      @max_concurrent_tool_tasks = nil
      @max_concurrent_workflow_tasks = nil
      @max_concurrent_llm_calls = nil
      @stream_queue_max_size = nil
      @max_concurrent_rag_fetches = nil
      @max_concurrent_vector_searches = nil
      @starvation_threshold_ms = 50
      @runtime_backend = :thread
      @strict_runtime_guards = false
    end
  end
end
