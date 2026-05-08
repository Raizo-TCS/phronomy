# frozen_string_literal: true

require "json"

module Phronomy
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
    #   store = Phronomy::VectorStore::Pgvector.new(model_class: VectorDocument)
    #   store.add(id: "doc1", embedding: [0.1, 0.9], metadata: {text: "hello"})
    #   results = store.search(query_embedding: [0.1, 0.8], k: 5)
    class Pgvector < Base
      # @param model_class [Class] ActiveRecord model with id/embedding/metadata columns
      def initialize(model_class:)
        begin
          require "pgvector"
        rescue LoadError
          raise LoadError,
            "pgvector gem is required for Phronomy::VectorStore::Pgvector. " \
            "Add `gem 'pgvector'` to your Gemfile."
        end
        @model_class = model_class
      end

      # @param id        [String]
      # @param embedding [Array<Float>]
      # @param metadata  [Hash]
      def add(id:, embedding:, metadata: {})
        @model_class.upsert(
          {id: id, embedding: safe_vector(embedding), metadata: metadata.to_json},
          unique_by: :id
        )
        self
      end

      # @param query_embedding [Array<Float>]
      # @param k               [Integer]
      # @return [Array<Hash>] sorted by descending similarity score
      def search(query_embedding:, k: 5)
        vec = safe_vector_literal(query_embedding)
        k_safe = Integer(k)
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
              metadata: JSON.parse(r.metadata.to_s, symbolize_names: true)
            }
          end
      end

      def clear
        @model_class.delete_all
        self
      end

      private

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
