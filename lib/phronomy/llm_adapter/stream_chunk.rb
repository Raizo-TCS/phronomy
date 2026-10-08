# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # Intermediate text notification; the final Response is authoritative.
    # @api public
    class StreamChunk
      attr_reader :content

      # @api public
      def initialize(content:)
        raise ArgumentError, "stream content must be a String or nil" unless content.nil? || content.is_a?(String)
        @content = content&.dup&.freeze
        freeze
      end
    end
  end
end
