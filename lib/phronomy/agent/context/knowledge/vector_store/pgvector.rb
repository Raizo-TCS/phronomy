# frozen_string_literal: true

require "json"

module Phronomy
  module Agent
    module Context
      module Knowledge
        module VectorStore
    # PostgreSQL-backed vector store using the pgvector extension.
    #
    # Requires:
    #   - The +pgvector+ gem (add to your Gemfile)
    #   - An ActiveRecord model class with the following columns:
    #       id        (string / uuid)
    #       embedding (vector — from the pgvector column type)
    #       metadata  (text or jsonb — stores arbitrary metadata as JSON)
    #
    # @example Usage
    #   store = Phronomy::Agent::Context::Knowledge::VectorStore::Pgvector.new(model_class: VectorDocument)
    #   store.add(id: "doc1", embedding: [0.1, 0.9], metadata: {text: "hello"})
    #   results = store.search(query_embedding: [0.1, 0.8], k: 5)
    class Pgvector < Base
      # @param model_class [Class]        ActiveRecord model with id/embedding/metadata columns
      # @param dimension   [Integer, nil] expected embedding dimension for Phronomy-side
      #   pre-validation.  When nil, dimension enforcement is delegated to the
      #   database schema; no pre-validation is performed by Phronomy.
      # @api public
      def initialize(model_class:, dimension: nil)
        begin
          require "pgvector"
        rescue LoadError
          raise LoadError,
            "pgvector gem is required for Phronomy::Agent::Context::Knowledge::VectorStore::Pgvector. " \
            "Add `gem 'pgvector'` to your Gemfile."
        end
        @model_class = model_class
        @dimension = dimension
      end

      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @api public
      def add(id:, embedding:, metadata: {}, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        validate_embedding_dimension!(embedding, @dimension)
        @model_class.upsert(
          {id: id, embedding: safe_vector(embedding), metadata: metadata.to_json},
          unique_by: :id
        )
        self
      end

      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @return [Array<Hash>] sorted by descending similarity score
      # @api public
      def search(query_embedding:, k: 5, cancellation_token: nil)
        cancellation_token&.raise_if_cancelled!
        k_safe = validate_k!(k)
        validate_embedding_dimension!(query_embedding, @dimension)
        vec = safe_vector_literal(query_embedding)
        conn = @model_class.connection
        quoted_vec = "#{conn.quote(vec)}::vector"

        @model_class
          .select("id, metadata, 1 - (embedding <=> #{quoted_vec}) AS score")
          .order("embedding <=> #{quoted_vec}")
          .limit(k_safe)
          .map do |r|
            {
              id: r.id.to_s,
              score: r.score.to_f,
              metadata: parse_metadata(r.metadata)
            }
          end
      end

      def remove(id:)
        @model_class.where(id: id).delete_all
        self
      end

      def clear
        @model_class.delete_all
        self
      end

      # Returns the number of documents in the backing table.
      def size
        @model_class.count
      end

      private

      # Parses a metadata value returned by the pg driver.
      # Handles NULL (nil), already-parsed Hash, and JSON string forms.
      def parse_metadata(raw)
        return {} if raw.nil?
        return symbolize_hash_keys(raw) if raw.is_a?(Hash)

        parsed = JSON.parse(raw.to_s, symbolize_names: true)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # Recursively symbolizes keys for an already-parsed Hash.
      def symbolize_hash_keys(hash)
        hash.each_with_object({}) do |(k, v), h|
          h[k.to_sym] = v.is_a?(Hash) ? symbolize_hash_keys(v) : v
        end
      end

      # Validates that all elements are numeric and converts to a pgvector-
      # compatible literal string (e.g. "[1.0,0.5,-0.3]").
      def safe_vector_literal(embedding)
        "[#{embedding.map { |v| Float(v) }.join(",")}]"
      end

      # Returns a validated vector for the upsert call.
      def safe_vector(embedding)
        safe_vector_literal(embedding)
      end
    end
  end
end
end
end
end
