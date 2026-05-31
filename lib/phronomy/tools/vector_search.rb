# frozen_string_literal: true

module Phronomy
  module Tools
    # A Capability::Base subclass that wraps a {Phronomy::VectorStore::Base} and
    # a {Phronomy::VectorStore::Embeddings::Base} adapter so that an agent can
    # perform semantic search as a tool call.
    #
    # Do not instantiate this class directly.  Use the factory method
    # {.from_store} to produce a configured subclass, then pass it to your agent.
    #
    # @example
    #   store = Phronomy::VectorStore::InMemory.new
    #   emb   = Phronomy::VectorStore::Embeddings::RubyLLMEmbeddings.new(model: "...")
    #   tool  = Phronomy::Tools::VectorSearch.from_store(store, embeddings: emb,
    #             k: 3, tool_name: "search_docs",
    #             description: "Search the company knowledge base.")
    #   agent = MyAgent.new
    #   agent.tools tool
    #
    # @api public
    class VectorSearch < Phronomy::Agent::Context::Capability::Base
      description "Search for relevant documents using semantic similarity."
      param :query, type: :string, desc: "The natural-language search query"

      class << self
        # Build a VectorSearch tool backed by the given store and embeddings adapter.
        #
        # @param store       [Phronomy::VectorStore::Base]
        # @param embeddings  [Phronomy::VectorStore::Embeddings::Base]
        # @param k           [Integer]       number of results to return (default 5)
        # @param tool_name   [String]        name exposed to the LLM
        # @param description [String, nil]   optional description override
        # @return [Class] anonymous subclass of VectorSearch configured with the given store
        # @api public
        def from_store(store, embeddings:, k: 5, tool_name: "vector_search", description: nil)
          klass = Class.new(self)
          klass.tool_name(tool_name)
          klass.description(description || "Search the vector store for documents similar to the query.")

          klass.define_method(:initialize) do
            @store = store
            @embeddings = embeddings
            @k = k
          end

          klass.define_method(:execute) do |query:|
            embedding = @embeddings.embed(query)
            results = @store.search(query_embedding: embedding, k: @k)
            return "No results found." if results.empty?

            results.map.with_index(1) do |r, i|
              content = r.dig(:metadata, :content) ||
                r.dig(:metadata, :text) ||
                r[:metadata].to_s
              "[#{i}] (score: #{r[:score].round(3)}) #{content}"
            end.join("\n")
          end

          klass
        end
      end

      # @api public
      def execute(query:)
        raise NotImplementedError, "Use VectorSearch.from_store to create a configured instance"
      end
    end
  end
end
