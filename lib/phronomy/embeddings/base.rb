# frozen_string_literal: true

require_relative "invalid_result_error"

module Phronomy
  module Embeddings
    # Owns input validation, the cancellation checkpoint and result validation.
    # Providers implement perform_embed; execution belongs to AsyncClient.
    # This contract selects no provider or vector store.
    # @api public
    class Base
      # @param text [String] empty text is allowed; model restrictions are provider-owned
      # @param cancellation_token [#raise_if_cancelled!, nil]
      # @return [Array<Float>] non-empty finite vector
      # @raise [ArgumentError] when input is not text
      # @raise [InvalidResultError] when the provider returns a malformed vector
      # @api public
      def embed(text, cancellation_token = nil)
        cancellation_token&.raise_if_cancelled!
        raise ArgumentError, "text must be a String" unless text.is_a?(String)
        vector = perform_embed(text, cancellation_token)
        unless vector.is_a?(Array) && !vector.empty? && vector.all? { |value|
          value.is_a?(Numeric) && value.real? && value.finite? && value.to_f.finite?
        }
          raise InvalidResultError, "embed must return a non-empty Array of finite real numbers"
        end
        vector.map(&:to_f)
      end

      protected

      # Provider extension point. Preserve cancellation and application errors;
      # SDK adapters translate their own provider errors to TransportError.
      # @param text [String]
      # @param cancellation_token [#raise_if_cancelled!, nil]
      # @return [Array<Numeric>]
      # @api public
      def perform_embed(text, cancellation_token = nil)
        raise NotImplementedError, "#{self.class}#perform_embed is not implemented"
      end
    end
  end
end
