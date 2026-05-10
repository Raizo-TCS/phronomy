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

    # Default StateStore instance (nil = no persistence)
    attr_accessor :default_state_store

    # Default Memory instance
    attr_accessor :default_memory

    # When true, all memory backends write asynchronously via ActiveJob by default.
    # Individual instances can still override with their own async: option.
    # Requires ActiveJob to be available.
    attr_accessor :memory_async

    # ActiveJob queue name used for async memory writes (default: :default)
    attr_accessor :memory_job_queue

    # Tracer instance
    attr_accessor :tracer

    # Global before_completion hook callable (Proc / lambda).
    # Called before every LLM request across all agents.
    # Receives a {Phronomy::Agent::BeforeCompletionContext}; must return a Hash
    # of params to merge, or nil to pass through unchanged.
    attr_accessor :before_completion

    # Recursion limit for graph execution (default: 25)
    attr_accessor :recursion_limit

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
      @memory_async = false
      @memory_job_queue = :default
    end
  end
end
