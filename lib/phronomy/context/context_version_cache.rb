# frozen_string_literal: true

module Phronomy
  module Context
    # Caches the assembled static system prompt text keyed by a SHA-256
    # fingerprint of the agent's instructions + static knowledge content.
    # Each instance is owned by one thread (stored in +Thread.current+).
    class ContextVersionCache
      # @return [String, nil] last stored fingerprint
      attr_reader :fingerprint

      # @return [String, nil] cached system prompt text
      attr_reader :system_text

      # @return [Integer] estimated token count of #system_text
      attr_reader :system_tokens

      def initialize
        @fingerprint = nil
        @system_text = nil
        @system_tokens = 0
      end

      # Returns true when the given fingerprint matches the stored one.
      #
      # @param fingerprint [String] SHA-256 hex digest to compare
      # @return [Boolean]
      # @api private
      def valid?(fingerprint)
        !@fingerprint.nil? && !@system_text.nil? && @fingerprint == fingerprint
      end

      # Update the cache with a new fingerprint and system text.
      #
      # @param fingerprint  [String] new SHA-256 hex digest
      # @param system_text  [String] fully assembled system prompt text
      # @api private
      def update(fingerprint:, system_text:)
        @fingerprint = fingerprint
        @system_text = system_text.to_s
        @system_tokens = TokenEstimator.estimate(@system_text)
      end

      # Clear all cached values (used for testing and forced invalidation).
      def reset
        @fingerprint = nil
        @system_text = nil
        @system_tokens = 0
      end
    end
  end
end
