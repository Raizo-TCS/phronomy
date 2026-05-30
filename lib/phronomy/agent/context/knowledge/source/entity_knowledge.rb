# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Knowledge
        module Source
          # A KnowledgeSource that extracts named-entity facts from conversation history.
          #
          # This is the knowledge-injection counterpart of the old EntityMemory.
          # It scans saved user messages with a regex heuristic (no LLM call) and
          # returns the discovered facts as a single knowledge chunk tagged :entity.
          #
          # EntityKnowledge is stateful: it accumulates extracted facts via #update(messages:)
          # which should be called each time new messages are saved.
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
          #   ks = Phronomy::Agent::Context::Knowledge::Source::EntityKnowledge.new
          #   ks.update(messages: chat_messages)
          #   agent.invoke("What is my name?", config: { knowledge_sources: [ks] })
          class EntityKnowledge < Base
            PATTERNS = [
              [:name, /\bmy name is\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
              [:identity, /\bI\s+am\s+([A-Z][A-Za-z0-9 \-']+)/],
              [:occupation, /\bI(?:'m| am) a(?:n)?\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
              [:workplace, /\bI (?:work|worked) (?:at|for|in)\s+([A-Za-z0-9][A-Za-z0-9 \-'.&,]*)/i],
              [:location, /\bI live in\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
              [:location, /\bI(?:'m| am) from\s+([A-Za-z][A-Za-z0-9 \-']*)/i],
              [:preference, /\bI (?:like|love|enjoy)\s+([A-Za-z][A-Za-z0-9 \-']*)/i]
            ].freeze

            def initialize
              @entities = {}
            end

            # Scan messages and accumulate entity facts.
            # Call this after saving a new set of messages (e.g. from a ConversationManager save hook).
            #
            # @param messages [Array] message objects responding to #role and #content
            # @api public
            def update(messages:)
              messages.each do |msg|
                next unless msg.role.to_sym == :user

                extract(msg.content.to_s).each { |key, value| @entities[key] = value }
              end
            end

            # Returns a single chunk containing all known entity facts in XML context format.
            # Returns an empty array when no entities have been discovered.
            #
            # @param query              [String, nil]                    unused — entity knowledge is always fully injected
            # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
            # @return [Array<Hash>]
            # @api public
            def fetch(query: nil, cancellation_token: nil)
              cancellation_token&.raise_if_cancelled!
              return [] if @entities.empty?

              lines = @entities.map { |key, value| "- #{key}: #{value}" }.join("\n")
              content = <<~CONTENT.chomp
                Known facts about the user:
                #{lines}
              CONTENT
              [{content: content, type: :entity}]
            end

            # Returns the current entity store (primarily for testing).
            #
            # @return [Hash]
            # @api public
            def entities
              @entities.dup
            end

            private

            def extract(text)
              found = {}
              PATTERNS.each do |key, pattern|
                if (match = text.match(pattern))
                  value = match[1].strip.sub(/[.!?]\s+.*$/, "").gsub(/[.,;!?]+$/, "")
                  found[key] = value unless value.empty?
                end
              end
              found
            end
          end
        end
      end
    end
  end
end
