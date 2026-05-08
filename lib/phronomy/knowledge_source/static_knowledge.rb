# frozen_string_literal: true

module Phronomy
  module KnowledgeSource
    # A KnowledgeSource backed by fixed text provided at construction time.
    #
    # Useful for injecting static documents, policy files, or configuration
    # knowledge that does not change per request.
    #
    # @example
    #   ks = Phronomy::KnowledgeSource::StaticKnowledge.new(
    #     "Our refund policy: ...",
    #     type: :policy
    #   )
    #   agent.invoke("What is the refund policy?", config: { knowledge_sources: [ks] })
    class StaticKnowledge < Base
      # @param text [String] the static knowledge text to inject
      # @param type [Symbol] semantic tag for the chunk (default :static)
      def initialize(text, type: :static)
        @text = text.to_s
        @type = type
      end

      # Returns the fixed text as a single chunk, regardless of query.
      #
      # @param query [String, nil] ignored for static knowledge
      # @return [Array<Hash>]
      def fetch(query: nil)
        return [] if @text.empty?

        [{content: @text, type: @type}]
      end
    end
  end
end
