# frozen_string_literal: true

require "json"

module Phronomy
  module VectorStore
    # Redis-backed vector store using the RediSearch module (FT.* commands).
    #
    # Requires:
    #   - The +redis+ gem (add to your Gemfile)
    #   - A Redis server with the RediSearch (RedisSearch) module enabled
    #     (or Redis Stack which bundles RediSearch)
    #
    # Vectors are stored as FLOAT32 binary blobs in Redis Hash fields and
    # searched using the KNN approximate-nearest-neighbour algorithm.
    #
    # @example Usage
    #   redis = Redis.new(url: "redis://localhost:6379")
    #   store = Phronomy::VectorStore::RedisSearch.new(redis: redis, dimension: 1536)
    #   store.add(id: "doc1", embedding: [0.1, 0.9], metadata: {text: "hello"})
    #   results = store.search(query_embedding: [0.1, 0.8], k: 5)
    class RedisSearch < Base
      DOC_PREFIX = "phronomy_doc:"
      private_constant :DOC_PREFIX

      # @param redis      [Redis]          configured Redis client
      # @param index_name [String]         RediSearch index name
      # @param dimension  [Integer, nil]   vector dimension; auto-detected on first add
      def initialize(redis:, index_name: "phronomy_vectors", dimension: nil)
        begin
          require "redis"
        rescue LoadError
          raise LoadError,
            "redis gem is required for Phronomy::VectorStore::RedisSearch. " \
            "Add `gem 'redis'` to your Gemfile."
        end
        @redis = redis
        @index_name = index_name
        @dimension = dimension
        @index_created = false
      end

      # @param id        [String]
      # @param embedding [Array<Float>]
      # @param metadata  [Hash]
      def add(id:, embedding:, metadata: {})
        ensure_index!(embedding.length)
        @redis.call(
          "HSET", "#{DOC_PREFIX}#{id}",
          "embedding", pack_vector(embedding),
          "metadata", metadata.to_json
        )
        self
      end

      # @param query_embedding [Array<Float>]
      # @param k               [Integer]
      # @return [Array<Hash>] sorted by descending similarity score
      def search(query_embedding:, k: 5)
        ensure_index!(query_embedding.length)
        k_safe = Integer(k)
        blob = pack_vector(query_embedding)

        raw = @redis.call(
          "FT.SEARCH", @index_name,
          "*=>[KNN #{k_safe} @embedding $BLOB AS score]",
          "PARAMS", 2, "BLOB", blob,
          "SORTBY", "score",
          "RETURN", 2, "score", "metadata",
          "DIALECT", 2
        )

        parse_results(raw)
      end

      def remove(id:)
        @redis.call("DEL", "#{DOC_PREFIX}#{id}")
        self
      end

      def clear
        begin
          @redis.call("FT.DROPINDEX", @index_name, "DD")
        rescue => e
          raise unless e.message.to_s.include?("Unknown Index name")
        end
        @index_created = false
        self
      end

      private

      def ensure_index!(dim)
        return if @index_created

        @dimension ||= dim
        begin
          @redis.call(
            "FT.CREATE", @index_name,
            "ON", "HASH",
            "PREFIX", 1, DOC_PREFIX,
            "SCHEMA",
            "embedding", "VECTOR", "FLAT", 6,
            "TYPE", "FLOAT32",
            "DIM", @dimension,
            "DISTANCE_METRIC", "COSINE",
            "metadata", "TEXT"
          )
        rescue => e
          raise unless e.message.to_s.include?("Index already exists")
        end
        @index_created = true
      end

      # Pack a Float array as a FLOAT32 binary string for RediSearch.
      def pack_vector(embedding)
        embedding.map { |v| Float(v) }.pack("f*")
      end

      # Parse the raw FT.SEARCH response into the standard Hash format.
      #
      # Redis FT.SEARCH returns: [count, key1, [field, value, ...], key2, ...]
      def parse_results(raw)
        return [] if raw.nil? || !raw.is_a?(Array) || raw.size < 2

        results = []
        i = 1
        while i < raw.size
          key = raw[i]
          fields = raw[i + 1]
          i += 2

          next unless fields.is_a?(Array)

          field_hash = fields.each_slice(2).to_h
          score_str = field_hash["score"]
          metadata_str = field_hash["metadata"]

          next if score_str.nil?

          id = key.to_s.delete_prefix(DOC_PREFIX)
          # RediSearch returns cosine distance (0=identical, 2=opposite);
          # convert to cosine similarity for consistency with other backends.
          score = 1.0 - score_str.to_f
          metadata = metadata_str ? JSON.parse(metadata_str, symbolize_names: true) : {}

          results << {id: id, score: score, metadata: metadata}
        end
        results
      end
    end
  end
end
