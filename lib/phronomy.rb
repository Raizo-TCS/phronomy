# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"

loader = Zeitwerk::Loader.for_gem
loader.ignore(File.expand_path("generators", __dir__))
# Teach Zeitwerk that "llm" maps to "LLM" so that file names such as
# ruby_llm_embeddings.rb resolve to RubyLLMEmbeddings (not RubyLlmEmbeddings).
loader.inflector.inflect("ruby_llm_embeddings" => "RubyLLMEmbeddings")
loader.setup

require_relative "phronomy/version"
require_relative "phronomy/token_usage"

require "phronomy/railtie" if defined?(Rails::Railtie)

module Phronomy
  # Exception hierarchy
  class Error < StandardError; end
  class ParseError < Error; end
  class RecursionLimitError < Error; end
  class ToolError < Error; end

  class ConfigurationError < Error; end

  class HandoffError < Error; end

  class GuardrailError < Error
    attr_reader :guardrail

    def initialize(message, guardrail: nil)
      super(message)
      @guardrail = guardrail
    end
  end

  # Namespace for graph-related classes (StateGraph, State, ParallelNode, …).
  # Also serves as the registry for State classes that may be serialized to
  # external stores (Redis, DB). Call +register_state_class+ at application
  # startup so that only known classes can be deserialized.
  module Graph
    @state_class_registry = nil
    @registry_mutex = Mutex.new

    class << self
      # Register one or more State classes that are allowed to be deserialized
      # by StateStore backends. When at least one class is registered, only
      # registered classes will be accepted by +StateStore::Base#safe_state_class+.
      #
      # Call this once at application startup (e.g. in a Rails initializer).
      #
      # @param classes [Array<Class>] classes including Phronomy::Graph::State
      # @example
      #   Phronomy::Graph.register_state_class(MyWorkflowState, OtherState)
      def register_state_class(*classes)
        @registry_mutex.synchronize do
          @state_class_registry ||= {}
          classes.each do |klass|
            raise ArgumentError, "#{klass.inspect} is not a Class" unless klass.is_a?(Class)
            @state_class_registry[klass.name] = klass
          end
        end
      end

      # Returns the current registry Hash, or nil when no class has been registered.
      # @return [Hash{String => Class}, nil]
      attr_reader :state_class_registry

      # Clears the registry. Primarily used in tests.
      def reset_state_class_registry!
        @registry_mutex.synchronize { @state_class_registry = nil }
      end
    end
  end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Resets configuration; primarily used in tests.
    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
