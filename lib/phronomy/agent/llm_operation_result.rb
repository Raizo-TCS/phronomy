# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable carrier for an LLM adapter operation result.
    #
    # BlockingAdapterPool worker or timer threads create this value, but do not
    # mutate AgentInvocation. FSMSession delivers it through :action_completed,
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
