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
    end
  end
end
