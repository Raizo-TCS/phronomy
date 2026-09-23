# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable carrier for one Provider operation outcome.
    #
    # The Provider Call identity is allocated on EventLoop before transport starts.
    # Worker completion carries that semantic identity back to the owning
    # FSMSession, which validates it against the currently active call before
    # applying any live state.
    #
    # @api private
    class LLMOperationResult
      attr_reader :llm_call_id, :response, :error, :streaming

      def initialize(llm_call_id:, response: nil, error: nil, streaming: false)
        id = llm_call_id&.to_s
        raise ArgumentError, "LLMOperationResult requires llm_call_id" if id.nil? || id.empty?

        @llm_call_id = id.freeze
        @response = response
        @error = error
        @streaming = !!streaming
        freeze
      end
    end
  end
end
