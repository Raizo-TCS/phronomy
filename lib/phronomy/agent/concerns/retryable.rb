# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Adds configurable retry behaviour to an agent.
      #
      # Included in {Phronomy::Agent::Base}. The retry loop wraps the full
      # #invoke_once call; {Phronomy::FilterBlockError} is never retried.
      # @api private
      module Retryable
        def self.included(base)
          base.extend(ClassMethods)
        end

        # Class-level DSL methods mixed into the including agent class.
        module ClassMethods
          # Configures a retry policy that wraps the full #invoke call.
          # FilterBlockError is never retried regardless of this setting.
          #
          # @param times [Integer] maximum retry attempts (default: 0)
          # @param wait  [Symbol, Numeric] :exponential, :linear, or a fixed Float
          # @param base  [Float]  base wait time in seconds (default: 1.0)
          #
          # @example
          #   class MyAgent < Phronomy::Agent::Base
          #     retry_policy times: 2, wait: :exponential, base: 1.0
          #   end
          # @api private
          def retry_policy(times: 0, wait: 0, base: 1.0)
            @_retry_policy = {times: times, wait: wait, base: base}
          end

          # Returns the configured retry policy, or nil when none is set.
          # @return [Hash, nil]
          attr_reader :_retry_policy

          # Injectable sleep callable for testing (shared with Tool::Base pattern).
          # @return [#call]
          # @api private
          def _sleep_proc
            @_sleep_proc || method(:sleep)
          end

          # Overrides the sleep callable used between retries.
          # @param proc [#call]
          attr_writer :_sleep_proc
        end

        private

        # Retry loop for #invoke.
        def _invoke_impl(input, messages: [], thread_id: nil, config: {})
          # Fail fast when the token is already cancelled before any LLM call.
          if (token = config[:cancellation_token]) && token.cancelled?
            raise Phronomy::CancellationError, "invocation cancelled"
          end

          policy = self.class._retry_policy
          attempt = 0
          begin
            _invoke_via_fsm(input, messages: messages, thread_id: thread_id, config: config)
          rescue Phronomy::FilterBlockError
            raise
          rescue Phronomy::CancellationError
            raise # Never retry after cancellation.
          rescue
            if policy && attempt < policy[:times]
              wait = compute_agent_retry_wait(policy[:wait], policy[:base], attempt)
              self.class._sleep_proc.call(wait) if wait > 0
              attempt += 1
              retry
            end
            translate_and_reraise!($!)
          end
        end

        # Computes the agent-level retry wait duration.
        # @param strategy [Symbol, Numeric]
        # @param base     [Float]
        # @param attempt  [Integer]
        # @return [Float]
        # @api private
        def compute_agent_retry_wait(strategy, base, attempt)
          case strategy
          when :exponential
            (2**attempt) * base
          when :linear
            (attempt + 1) * base
          when Numeric
            strategy.to_f
          else
            base.to_f
          end
        end
      end
    end
  end
end
