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
            "pgvector gem is required for Phronomy::VectorStore::Pgvector. " \
            "Add `gem 'pgvector'` to your Gemfile."
        end
        @model_class = model_class
        @dimension = dimension
      end

      protected

      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @api public
      def perform_add(id:, embedding:, metadata: {}, cancellation_token: nil)
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
      def perform_search(query_embedding:, k: 5, cancellation_token: nil)
        vec = safe_vector_literal(query_embedding)
        conn = @model_class.connection
        quoted_vec = "#{conn.quote(vec)}::vector"

        @model_class
          .select("id, metadata, 1 - (embedding <=> #{quoted_vec}) AS score")
          .order("embedding <=> #{quoted_vec}")
          .limit(k)
          .map do |r|
            {
              id: parse_id(r.id),
              score: parse_score(r.score),
              metadata: parse_metadata(r.metadata)
            }
          end
      end

      def perform_remove(id:)
        @model_class.where(id: id).delete_all
        self
      end

      def perform_clear
        @model_class.delete_all
        self
      end

      # Returns the number of documents in the backing table.
      def perform_size
        @model_class.count
      end

      # @api public
      def embedding_dimension
        @dimension
      end

      private

      def parse_id(raw)
        unless raw.is_a?(String) || raw.is_a?(Integer)
          raise InvalidResultError, "Pgvector returned an invalid document id"
        end
        raw.to_s
      end

      def parse_score(raw)
        valid = (raw.is_a?(String) && raw.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)) ||
          (raw.is_a?(Numeric) && raw.real?)
        value = Float(raw, exception: false) if valid
        unless value&.finite?
          raise InvalidResultError, "Pgvector requires a finite numeric score"
        end
        value
      end

      # Parses a metadata value returned by the pg driver.
      # Handles NULL (nil), already-parsed Hash, and JSON string forms.
      def parse_metadata(raw)
        return {} if raw.nil?
        return symbolize_hash_keys(raw) if raw.is_a?(Hash)

        unless raw.is_a?(String)
          raise InvalidResultError, "Pgvector metadata must contain a JSON object"
        end
        parsed = JSON.parse(raw, symbolize_names: true)
        unless parsed.is_a?(Hash)
          raise InvalidResultError, "Pgvector metadata must contain a JSON object"
        end
        parsed
      rescue JSON::ParserError
        raise InvalidResultError, "Pgvector metadata contains invalid JSON"
      end

      # Recursively symbolizes keys for an already-parsed Hash.
      def symbolize_hash_keys(hash)
        hash.each_with_object({}) do |(k, v), h|
          unless k.is_a?(String) || k.is_a?(Symbol)
            raise InvalidResultError, "Pgvector metadata contains an invalid object key"
          end
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
