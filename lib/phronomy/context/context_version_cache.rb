# frozen_string_literal: true

module Phronomy
  module Context
    # Caches the assembled static system prompt text per agent instance.
    #
    # The cache is keyed by a SHA-256 fingerprint computed from the agent's
    # instruction text and the content of all registered static knowledge
    # sources. When the fingerprint matches the stored value the previously
    # assembled system_text is reused without re-fetching any sources.
    #
    # A cache miss (fingerprint changed or first call) triggers a full
    # rebuild: instruction + static-knowledge XML tags are concatenated and
    # the result is stored alongside the new fingerprint.
    #
    # Each agent *instance* holds one cache object. The cache persists across
    # #invoke calls on the same instance, which is the typical usage pattern
    # for long-running agents.
    class ContextVersionCache
      # @return [String, nil] last stored fingerprint
      attr_reader :fingerprint

      # @return [String, nil] cached system prompt text
      attr_reader :system_text

      # @return [Integer] estimated token count of #system_text
      attr_reader :system_tokens

      def initialize
        @mutex = Mutex.new
        @fingerprint = nil
        @system_text = nil
        @system_tokens = 0
      end

      # Returns true when the given fingerprint matches the stored one.
      # The check is performed under a mutex so that a concurrent #update cannot
      # expose a partially-written state where fingerprint is new but system_text
      # is still nil (Issue #55).
      #
      # @param fingerprint [String] SHA-256 hex digest to compare
      # @return [Boolean]
      def valid?(fingerprint)
        @mutex.synchronize do
          !@fingerprint.nil? && !@system_text.nil? && @fingerprint == fingerprint
        end
      end

      # Update the cache with a new fingerprint and system text.
      # All three assignments are performed atomically under a mutex so that
      # concurrent readers never observe a partial state (Issue #55).
      #
      # @param fingerprint  [String] new SHA-256 hex digest
      # @param system_text  [String] fully assembled system prompt text
      def update(fingerprint:, system_text:)
        @mutex.synchronize do
          @fingerprint = fingerprint
          @system_text = system_text.to_s
          @system_tokens = TokenEstimator.estimate(@system_text)
        end
      end

      # Clear all cached values (used for testing and forced invalidation).
      def reset
        @mutex.synchronize do
          @fingerprint = nil
          @system_text = nil
          @system_tokens = 0
        end
      end
    end
  end
end
