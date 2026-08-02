# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable carrier for one LLM adapter operation outcome.
    #
    # Worker/timer threads create this value without mutating AgentInvocation.
    # AgentInvocationSessionBuilder posts it as :llm_completed or :llm_failed,
    # and AgentInvocation applies it on the EventLoop thread.
    #
    # @api private
    class LLMOperationResult
      attr_reader :response, :error, :streaming

      def initialize(response: nil, error: nil, streaming: false)
        @response = response
        @error = error
        @streaming = streaming
        freeze
      end
    end
  end
end
