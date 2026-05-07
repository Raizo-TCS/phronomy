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

    # Tracer instance
    attr_accessor :tracer

    # Recursion limit for graph execution (default: 25)
    attr_accessor :recursion_limit

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
    end
  end
end
