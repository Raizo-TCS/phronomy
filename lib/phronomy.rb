# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"
require_relative "phronomy/ruby_llm_patches"

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

  # Registry for WorkflowContext classes that may be serialized to external stores
  # (Redis, DB). Call +register_workflow_context+ at application startup so that
  # only known classes can be deserialized.
  @workflow_context_registry = nil
  @registry_mutex = Mutex.new

  class << self
    # Register one or more WorkflowContext classes that are allowed to be
    # deserialized by StateStore backends. When at least one class is registered,
    # only registered classes will be accepted by
    # +StateStore::Base#safe_state_class+.
    #
    # Call this once at application startup (e.g. in a Rails initializer).
    #
    # @param classes [Array<Class>] classes including Phronomy::WorkflowContext
    # @example
    #   Phronomy.register_workflow_context(ScanContext, OtherContext)
    def register_workflow_context(*classes)
      @registry_mutex.synchronize do
        @workflow_context_registry ||= {}
        classes.each do |klass|
          raise ArgumentError, "#{klass.inspect} is not a Class" unless klass.is_a?(Class)
          @workflow_context_registry[klass.name] = klass
        end
      end
    end

    # Returns the current registry Hash, or nil when no class has been registered.
    # @return [Hash{String => Class}, nil]
    attr_reader :workflow_context_registry

    # Clears the registry. Primarily used in tests.
    def reset_workflow_context_registry!
      @registry_mutex.synchronize { @workflow_context_registry = nil }
    end

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
