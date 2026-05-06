# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  "llm_chain" => "LLMChain"
)
loader.ignore(File.expand_path("generators", __dir__))
loader.setup

require_relative "phronomy/version"

require "phronomy/railtie" if defined?(Rails::Railtie)

module Phronomy
  # Exception hierarchy
  class Error < StandardError; end
  class ParseError < Error; end
  class RecursionLimitError < Error; end
  class Interrupt < Error
    attr_reader :node, :state

    def initialize(node: nil, state: nil, msg: "Graph execution interrupted")
      super(msg)
      @node = node
      @state = state
    end
  end
  class CheckpointError < Error; end
  class ToolError < Error; end
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
