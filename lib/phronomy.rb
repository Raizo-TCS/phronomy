# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"
require_relative "phronomy/ruby_llm_patches"

loader = Zeitwerk::Loader.for_gem
# Teach Zeitwerk that "llm" maps to "LLM" so that file names such as
# ruby_llm_embeddings.rb resolve to RubyLLMEmbeddings (not RubyLlmEmbeddings).
loader.inflector.inflect("ruby_llm_embeddings" => "RubyLLMEmbeddings")
# FSMSession: Zeitwerk would infer "FsmSession" — override to "FSMSession".
loader.inflector.inflect("fsm_session" => "FSMSession")
loader.setup

require_relative "phronomy/version"
require_relative "phronomy/token_usage"

module Phronomy
  # Exception hierarchy
  class Error < StandardError; end
  class ParseError < Error; end
  class RecursionLimitError < Error; end
  class ToolError < Error; end

  class ConfigurationError < Error; end

  class HandoffError < Error; end

  # Raised by {Phronomy::GeneratorVerifier#invoke} when +raise_if_untrusted: true+
  # and the pipeline's combined confidence score falls below the configured threshold.
  #
  # @example
  #   rescue Phronomy::LowConfidenceError => e
  #     puts e.result.confidence   # => e.g. 0.45
  #     puts e.result.output       # best-effort answer despite low confidence
  class LowConfidenceError < Error
    # @return [Phronomy::GeneratorVerifier::Result] the untrusted result
    attr_reader :result

    def initialize(result)
      @result = result
      super("Answer confidence #{result.confidence} is below the required threshold")
    end
  end

  class GuardrailError < Error
    attr_reader :guardrail

    def initialize(message, guardrail: nil)
      super(message)
      @guardrail = guardrail
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
