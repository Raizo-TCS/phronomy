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
# AgentFSM: Zeitwerk would infer "Fsm" — override to "FSM".
loader.inflector.inflect("fsm" => "FSM")
loader.setup

require_relative "phronomy/version"
require_relative "phronomy/token_usage"

module Phronomy
  # Exception hierarchy
  class Error < StandardError; end
  class ParseError < Error; end
  class RecursionLimitError < Error; end
  class ToolError < Error; end
  # Raised when an agent invocation exceeds the timeout set via +invoke_timeout+.
  class TimeoutError < Error; end

  class ConfigurationError < Error; end

  class HandoffError < Error; end

  # Raised when a network or transport layer call fails (e.g. LLM API unreachable,
  # MCP server connection refused). Distinguishable from application-level errors
  # so callers can apply network-specific retry logic.
  class TransportError < Error; end

  # Raised when the LLM API returns a rate-limit response (HTTP 429 or equivalent).
  # Callers should back off and retry after the indicated delay.
  class RateLimitError < TransportError; end

  # Raised when the LLM API rejects the request due to an invalid or revoked API key.
  # Callers should not retry without fixing the credentials.
  class AuthenticationError < TransportError; end

  # Raised when the prompt exceeds the model's context window limit.
  class ContextLengthError < Error; end

  # Raised when a workflow or agent execution is explicitly cancelled.
  # Separate from TimeoutError (deadline exceeded) — this is an intentional stop.
  class CancellationError < Error; end

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

  # Raised when an operation is submitted to a {BlockingAdapterPool} that has
  # already been shut down via {BlockingAdapterPool#shutdown}.
  class PoolShutdownError < Error; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    # Resets the global Phronomy configuration to defaults.
    #
    # **Intended for test suites only.** Calling this in a production process
    # will drop all runtime configuration (tracer, model, tokenizer, etc.)
    # globally and immediately affect all subsequent agent and workflow calls.
    #
    # **Parallel test suites warning:** When tests run in parallel (e.g.
    # `parallel_tests` or `parallel_rspec`), +reset_configuration!+ in one
    # worker will clear configuration shared with other workers in the same
    # process. Prefer process-isolation strategies (forked workers) over
    # thread-based parallelism when using this method.
    #
    # Typical usage in a sequential test suite:
    #   after { Phronomy.reset_configuration! }
    def reset_configuration!
      @configuration = Configuration.new
    end

    # Yields the current {Configuration} object, then restores the original
    # configuration on exit (even if the block raises).
    #
    # Intended for test helpers that need to temporarily override settings
    # without permanently mutating the global configuration.
    #
    # @yield [config] the current {Configuration} instance (mutable)
    # @example
    #   Phronomy.with_configuration do |c|
    #     c.logger = Logger.new($stdout)
    #   end
    # @api public
    def with_configuration
      original = @configuration&.dup
      yield configuration
    ensure
      @configuration = original
    end

    # Resets all Phronomy runtime state: configuration and the EventLoop
    # singleton (if running).
    #
    # **Intended for test suites only.**  Stops any running EventLoop thread,
    # clears the EventLoop singleton, and resets configuration to defaults.
    # Call once before/after each example to ensure test isolation.
    #
    # @example
    #   config.around { |ex| Phronomy.reset_runtime! ; ex.run ; Phronomy.reset_runtime! }
    # @api public
    def reset_runtime!
      Phronomy::EventLoop.reset!
      @configuration = Configuration.new
    end
  end
end
