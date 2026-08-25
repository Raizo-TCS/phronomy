# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"
require_relative "phronomy/ruby_llm_patches"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect("ruby_llm_embeddings" => "RubyLLMEmbeddings")
loader.inflector.inflect("rag" => "RAG")
loader.inflector.inflect("fsm_session" => "FSMSession")
loader.inflector.inflect("llm_adapter" => "LLMAdapter")
loader.inflector.inflect("llm_operation_result" => "LLMOperationResult")
loader.inflector.inflect("ruby_llm" => "RubyLLM")
loader.inflector.inflect("canonical_json" => "CanonicalJSON")
loader.inflector.inflect("ruby_llm_materializer" => "RubyLLMMaterializer")
loader.inflector.inflect("llm_call_record" => "LLMCallRecord")
loader.inflector.inflect("llm_input_manifest" => "LLMInputManifest")
loader.inflector.inflect("llm_input_build_context" => "LLMInputBuildContext")
loader.inflector.inflect("llm_input_patch" => "LLMInputPatch")
loader.inflector.inflect("before_llm_input" => "BeforeLLMInput")
loader.collapse("#{__dir__}/phronomy/engine")
# Loaded via require_relative before loader.setup; ignore to avoid Zeitwerk constant-name mismatch.
loader.ignore("#{__dir__}/phronomy/ruby_llm_patches.rb")
# Persistence backend conformance tests are explicit test support. Keep them out
# of production eager-load so ordinary `require "phronomy"` never requires RSpec.
loader.ignore(
  "#{__dir__}/phronomy/testing/persistence_contract.rb",
  "#{__dir__}/phronomy/testing/persistence_contract"
)
loader.setup

require_relative "phronomy/version"
require_relative "phronomy/token_usage"

module Phronomy
  class Error < StandardError; end
  class ParseError < Error; end
  class RecursionLimitError < Error; end
  class ToolError < Error; end
  class TimeoutError < Error; end
  class ConfigurationError < Error; end
  class HandoffError < Error; end

  class TransportError < Error; end
  class RateLimitError < TransportError; end
  class AuthenticationError < TransportError; end
  class ContextLengthError < Error; end
  class CancellationError < Error; end

  # Raised when a synchronous API would block the EventLoop control thread.
  class EventLoopReentrancyError < Error; end

  # Backward-compatible error class name for callers that still rescue the old
  # scheduler-oriented exception. New code should use EventLoopReentrancyError.
  class SchedulerReentrancyError < EventLoopReentrancyError; end

  class RuntimeShutdownError < Error; end
  class RuntimeShutdownReentrancyError < RuntimeShutdownError; end

  class LowConfidenceError < Error
    attr_reader :result

    def initialize(result)
      @result = result
      super("Answer confidence #{result.confidence} is below the required threshold")
    end
  end

  class FilterBlockError < Error
    attr_reader :filter

    def initialize(message, filter: nil)
      super(message)
      @filter = filter
    end
  end

  class PoolShutdownError < Error; end
  class BackpressureError < Error; end

  class WorkflowContextOwnershipError < Error; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def with_configuration
      original = @configuration&.dup
      yield configuration
    ensure
      @configuration = original
    end

    def reset_runtime!(timeout: configuration.event_loop_stop_grace_seconds)
      previous_grace = @configuration&.event_loop_stop_grace_seconds
      result = Runtime.reset_default!(timeout: timeout)

      new_configuration = Configuration.new
      if previous_grace
        new_configuration.event_loop_stop_grace_seconds = previous_grace
      end
      @configuration = new_configuration
      result
    end
  end
end

# Shared Recovery primitives and Workflow Persistence F1 reconciliation.
# Entity-specific Agent Recovery is loaded from lib/phronomy/agent.rb when the
# Agent namespace is materialized.
require_relative "phronomy/recovery"
require_relative "phronomy/workflow_recovery"
