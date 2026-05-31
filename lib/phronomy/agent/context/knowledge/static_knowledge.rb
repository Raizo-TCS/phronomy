# frozen_string_literal: true

module Phronomy
  module Agent
    module Context
      module Knowledge
        # A KnowledgeSource backed by fixed text provided at construction time.
        #
        # Useful for injecting static documents, policy files, or configuration
        # knowledge that does not change per request.
        #
        # @example
        #   ks = Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
        #     "Our refund policy: ...",
        #     type: :policy
        #   )
        #   agent.invoke("What is the refund policy?", config: { knowledge_sources: [ks] })
        class StaticKnowledge < Base
          # @param text   [String] the static knowledge text to inject
          # @param type   [Symbol] semantic tag for the chunk (default :static)
          # @param source [String, nil] label identifying where this knowledge came from
          #   (e.g. a filename). Included in the context XML tag and exposed to the LLM
          #   so that agents can produce grounded citations.
          # @api public
          def initialize(text, type: :static, source: nil)
            @text = text.to_s
            @type = type
            @source = source
          end

          # Returns the fixed text as a single chunk, regardless of query.
          #
          # @param query              [String, nil]                    ignored for static knowledge
          # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil] optional; raises CancellationError when cancelled
          # @return [Array<Hash>]
          # @api public
          def fetch(query: nil, cancellation_token: nil)
            cancellation_token&.raise_if_cancelled!
            return [] if @text.empty?

            chunk = {content: @text, type: @type}
            chunk[:source] = @source if @source
            [chunk]
          end

          # Static knowledge content never changes between invocations.
          # @return [true]
          # @api public
          def static?
            true
          end
        end
      end
    end
  end
end
