# frozen_string_literal: true

require "zeitwerk"
require "ruby_llm"
require_relative "phronomy/ruby_llm_patches"

loader = Zeitwerk::Loader.for_gem
# Teach Zeitwerk that "llm" maps to "LLM" so that file names such as
# ruby_llm_embeddings.rb resolve to RubyLLMEmbeddings (not RubyLlmEmbeddings).
loader.inflector.inflect("ruby_llm_embeddings" => "RubyLLMEmbeddings")
# RAG: Zeitwerk would infer "Rag" — override to "RAG".
loader.inflector.inflect("rag" => "RAG")
# FSMSession: Zeitwerk would infer "FsmSession" — override to "FSMSession".
# Phronomy::FSMSession is the top-level cooperative execution engine shared by
# WorkflowRunner and Agent::InvocationSession.
loader.inflector.inflect("fsm_session" => "FSMSession")
# LLMAdapter: Zeitwerk would infer "LlmAdapter" — override to "LLMAdapter".
loader.inflector.inflect("llm_adapter" => "LLMAdapter")
# LLMAdapter::RubyLLM: "ruby_llm" maps to "RubyLLM" (not "RubyLlm").
loader.inflector.inflect("ruby_llm" => "RubyLLM")
# Collapse engine/ so that its contents autoload directly under Phronomy::
# (no Engine:: prefix).  e.g. engine/event_loop.rb => Phronomy::EventLoop.
# This allows the execution engine to be organised in its own subdirectory
# without changing any class names or callers.
loader.collapse("#{__dir__}/phronomy/engine")
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

  # Raised when {Agent#invoke} (a synchronous, blocking call) is attempted from
  # inside an active scheduler task and +strict_runtime_guards+ is enabled.
  #
  # Calling a blocking invocation from within a scheduler task stalls the
  # scheduler until the inner invocation completes, preventing other tasks from
  # making progress (hidden deadlock risk).  Use {Agent#invoke_async} followed by
  # +#await+ inside scheduler tasks instead.
  #
  # This error is only raised when:
  #   Phronomy.configure { |c| c.strict_runtime_guards = true }
  #
  # By default a warning is logged and execution continues.
  #
  # @see Phronomy::Runtime.in_scheduler_context?
  class SchedulerReentrancyError < Error; end

  # Raised when work is submitted to a Runtime whose shutdown has begun, or
  # when a Runtime cannot be reset because owned resources are still alive.
  class RuntimeShutdownError < Error; end

  # Raised when Runtime#shutdown is invoked from inside a Phronomy::Task.
  class RuntimeShutdownReentrancyError < RuntimeShutdownError; end

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

  # Raised by a {Phronomy::Filter::Base} subclass when the filter rejects a
  # value without transforming it (blocking the pipeline).
  # @api public
  class FilterBlockError < Error
    attr_reader :filter

    def initialize(message, filter: nil)
      super(message)
      @filter = filter
    end
  end

  # Raised when an operation is submitted to a {BlockingAdapterPool} that has
  # already been shut down via {BlockingAdapterPool#shutdown}.
  class PoolShutdownError < Error; end

  # Raised when a concurrency limit is exceeded and the configured backpressure
  # strategy is +:raise+. The caller should back off and retry.
  class BackpressureError < Error; end

  # Raised by {CancellationScope#pop_queue} when the deadline expires before a
  # result is available. Extends {TimeoutError} for backwards compatibility.
  class ScopeTimeoutError < TimeoutError; end

  # Raised when a Workflow entry/exit action task exceeds the +action_timeout:+
  # configured for its state.  Extends {TimeoutError}.
  class ActionTimeoutError < TimeoutError; end

  # Raised when a {Phronomy::WorkflowContext} field is mutated from a thread
  # that does not own the context (i.e. not the EventLoop dispatch thread).
  # Only raised in EventLoop mode.  Use +context.merge(...)+ to produce a new
  # context, or deliver updates as +:action_completed+ event payloads
  # via {Agent::Base#invoke_async} + {Task#map}.
  class WorkflowContextOwnershipError < Error; end

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

    # Shuts down and clears the process-wide default Runtime, then resets
    # global configuration. Intended for test suites only.
    #
    # Runtime execution failure and resource cleanup are separate. The
    # singleton is cleared when cleanup completed, even if execution failed.
    #
    # @param timeout [Numeric] maximum graceful wait for Runtime tasks and
    #   EventLoop shutdown
    # @return [Phronomy::Runtime::ShutdownResult]
    # @api public
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
