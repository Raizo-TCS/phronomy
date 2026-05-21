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

    # When true (default), user input and LLM output are recorded in trace spans.
    # Set to false in privacy-sensitive environments to prevent PII from reaching
    # the tracing backend (OTel, Langfuse, etc.).
    attr_accessor :trace_pii

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
      @trace_pii = true
      @event_loop = false
    end
  end
end
