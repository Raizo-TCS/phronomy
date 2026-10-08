# frozen_string_literal: true

require_relative "request"
require_relative "response"
require_relative "stream_chunk"
require_relative "invalid_result_error"

module Phronomy
  module LLMAdapter
    # Owns one-turn operations. Backends implement protected synchronous hooks.
    # SDK construction and translation happen entirely inside those hooks.
    # @api public
    class Base
      # @api public
      def identity
        {"adapter_name" => self.class.name}.freeze
      end

      # Local model metadata only. Missing capacity is permitted.
      # @api public
      def input_budget(model_config)
        nil
      end

      # @api public
      def complete(request, cancellation_token: nil)
        validate_request!(request, cancellation_token)
        response = perform_complete(request, cancellation_token: cancellation_token)
        cancellation_token&.raise_if_cancelled!
        validate_response!(response)
      end

      # Notifications run on the caller thread. AsyncClient supplies an internal
      # event sink; application callbacks remain with their owning domain.
      # @api public
      def stream(request, cancellation_token: nil)
        raise ArgumentError, "stream requires a block" unless block_given?
        validate_request!(request, cancellation_token)
        response = perform_stream(request, cancellation_token: cancellation_token) do |chunk|
          cancellation_token&.raise_if_cancelled!
          raise InvalidResultError, "stream must yield StreamChunk values" unless chunk.is_a?(StreamChunk)
          yield chunk
        end
        cancellation_token&.raise_if_cancelled!
        validate_response!(response)
      end

      protected

      # @api public
      def perform_complete(request, cancellation_token:)
        raise NotImplementedError, "#{self.class}#perform_complete is not implemented"
      end

      # @api public
      def perform_stream(request, cancellation_token:, &block)
        raise NotImplementedError, "#{self.class}#perform_stream is not implemented"
      end

      private

      def validate_request!(request, token)
        token&.raise_if_cancelled!
        raise ArgumentError, "LLM operation requires a Request" unless request.is_a?(Request)
      end

      def validate_response!(response)
        raise InvalidResultError, "LLM operation must return a Response" unless response.is_a?(Response)
        response
      end
    end
  end
end
