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

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
      @trace_pii = false
      @event_loop = false
      @event_loop_stop_grace_seconds = 5
    end
  end
end
