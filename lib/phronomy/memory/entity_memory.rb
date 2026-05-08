# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Memory
    # Entity-tracking memory.
    #
    # Extracts named-entity facts from user messages using a regex heuristic
    # (no LLM call required). Extracted facts are stored per-thread in a
    # key-value store and injected as a system context message when
    # load_messages is called, so the agent always "remembers" stated facts.
    #
    # Supported extraction patterns (case-insensitive):
    #   "my name is Alice"          → { name: "Alice" }
    #   "I am Alice"                → { identity: "Alice" }
    #   "I'm a software engineer"   → { occupation: "software engineer" }
    #   "I work at / for Acme"      → { workplace: "Acme" }
    #   "I live in Tokyo"           → { location: "Tokyo" }
    #   "I'm from Tokyo"            → { location: "Tokyo" }
    #   "I like / love Ruby"        → { preference: "Ruby" }
    #
    # @example
    #   memory = Phronomy::Memory::EntityMemory.new
    #   # ... attach to an agent via config
    class EntityMemory < Base
      PATTERNS = [
        [:name, /\bmy name is\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
        [:identity, /\bI\s+am\s+([A-Z][A-Za-z0-9 \-']+)/],
        [:occupation, /\bI(?:'m| am) a(?:n)?\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
        [:workplace, /\bI (?:work|worked) (?:at|for|in)\s+([A-Za-z0-9][A-Za-z0-9 \-'.&,]*)/i],
        [:location, /\bI live in\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
        [:location, /\bI(?:'m| am) from\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
        [:preference, /\bI (?:like|love|enjoy)\s+([A-Za-z][A-Za-z0-9 \-']*)/i]
      ].freeze

      def initialize(k: 20)
        @k = k
        @store = {}    # thread_id => Array of messages
        @entities = {} # thread_id => Hash{ key => value }
      end

      # Returns recent messages plus an entity-context system message (when entities exist).
      #
      # @param thread_id    [String]
      # @param token_budget [Phronomy::Context::TokenBudget, nil]
      # @return [Array]
      def load_messages(thread_id:, token_budget: nil, query: nil, **)
        messages = @store[thread_id] || []
        recent = token_budget ? fit_to_budget(messages, token_budget.effective_input_limit) : messages.last(@k * 2)

        entity_msg = entity_context_message(thread_id)
        entity_msg ? [entity_msg] + recent : recent
      end

      def save_messages(thread_id:, messages:, **)
        @store[thread_id] = messages
        extract_and_store_entities(thread_id, messages)
      end

      def clear(thread_id:)
        @store.delete(thread_id)
        @entities.delete(thread_id)
      end

      # Returns a copy of the current entity store for a thread (primarily for testing).
      #
      # @param thread_id [String]
      # @return [Hash]
      def entities_for(thread_id)
        (@entities[thread_id] || {}).dup
      end

      private

      # Scans user messages and merges discovered entities.
      def extract_and_store_entities(thread_id, messages)
        store = @entities[thread_id] ||= {}
        messages.each do |msg|
          next unless msg.role.to_sym == :user

          extract(msg.content.to_s).each { |key, value| store[key] = value }
        end
      end

      # Applies all PATTERNS to +text+ and returns a Hash of discovered entities.
      def extract(text)
        found = {}
        PATTERNS.each do |key, pattern|
          if (match = text.match(pattern))
            # Last capture group holds the entity value.
            # First strip text following a sentence boundary (e.g. ". Just say...").
            value = match[1].strip.sub(/[.!?]\s+.*$/, "").gsub(/[.,;!?]+$/, "")
            found[key] = value unless value.empty?
          end
        end
        found
      end

      def entity_context_message(thread_id)
        entities = @entities[thread_id]
        return nil if entities.nil? || entities.empty?

        lines = entities.map { |key, value| "- #{key}: #{value}" }.join("\n")
        content = "Known facts about the user:\n#{lines}"
        OpenStruct.new(role: :system, content: content)
      end

      def fit_to_budget(messages, token_limit)
        accumulated = 0
        result = []
        messages.reverse_each do |msg|
          tokens = Phronomy::Context::TokenEstimator.estimate(msg.content.to_s)
          break if accumulated + tokens > token_limit

          accumulated += tokens
          result.unshift(msg)
        end
        result
      end
    end
  end
end
