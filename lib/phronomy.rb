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
