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

    # Default Checkpointer instance
    attr_accessor :default_checkpointer

    # Default Memory instance
    attr_accessor :default_memory

    # Tracer instance
    attr_accessor :tracer

    # Recursion limit for graph execution (default: 25)
    attr_accessor :recursion_limit

    # Interrupt handler for Human-in-the-Loop (Proc or nil)
    attr_accessor :interrupt_handler

    def initialize
      @recursion_limit = 25
      @tracer = Phronomy::Tracing::NullTracer.new
    end
  end
end
