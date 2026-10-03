# frozen_string_literal: true

require "json"

module Phronomy
  module VectorStore
    # Redis-backed vector store using the RediSearch module (FT.* commands).
    #
    # Requires:
    #   - The +redis+ gem (add to your Gemfile)
    #   - A RESP2 Redis client and a server with the RediSearch module enabled
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
      # @param dimension  [Integer, nil]   vector dimension; auto-detected on first add.
      #   When connecting to an **existing** RediSearch index, you MUST pass
      #   dimension: explicitly.  Without it, a freshly constructed instance
      #   treats the index as uninitialized until #add is called, and #search
      #   silently returns [] in the meantime.
      # @api public
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
        @mutex = Mutex.new
      end

      protected

      # @param id                 [String]
      # @param embedding          [Array<Float>]
      # @param metadata           [Hash]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @api public
      def perform_add(id:, embedding:, metadata: {}, cancellation_token: nil)
        # Establish expected dimension on first add (not race-free for concurrent
        # first adds), then create/reuse the index. Base has validated the input.
        @dimension ||= embedding.size
        ensure_index!(@dimension)
        @redis.call(
          "HSET", "#{DOC_PREFIX}#{id}",
          "embedding", pack_vector(embedding),
          "metadata", metadata.to_json
        )
        self
      end

      # @param query_embedding    [Array<Float>]
      # @param k                  [Integer]
      # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
      # @return [Array<Hash>] sorted by descending similarity score
      # @api public
      def perform_search(query_embedding:, k: 5, cancellation_token: nil)
        # search never establishes dimension.  If dimension is unknown and the
        # index has not been created yet, there are no documents to return.
        return [] if @dimension.nil? && !@index_created

        ensure_index!(@dimension)
        blob = pack_vector(query_embedding)

        raw = @redis.call(
          "FT.SEARCH", @index_name,
          "*=>[KNN #{k} @embedding $BLOB AS score]",
          "PARAMS", 2, "BLOB", blob,
          "SORTBY", "score",
          "RETURN", 2, "score", "metadata",
          "DIALECT", 2
        )

        parse_results(raw)
      end

      def perform_remove(id:)
        @redis.call("DEL", "#{DOC_PREFIX}#{id}")
        self
      end

      # Returns the number of documents indexed.
      # Queries FT.INFO when the index has been created; returns 0 otherwise.
      def perform_size
        return 0 unless @index_created

        fields = parse_fields(@redis.call("FT.INFO", @index_name), "FT.INFO")
        count = fields["num_docs"]
        count = Integer(count, 10) if count.is_a?(String) && count.match?(/\A\d+\z/)
        unless count.is_a?(Integer) && count >= 0
          raise InvalidResultError, "Redis FT.INFO requires a non-negative integer num_docs"
        end
        count
      end

      def perform_clear
        @mutex.synchronize do
          begin
            @redis.call("FT.DROPINDEX", @index_name, "DD")
          rescue => e
            raise unless e.message.to_s.include?("Unknown Index name")
          end
          @index_created = false
        end
        self
      end

      # @api public
      def embedding_dimension
        @dimension
      end

      private

      def ensure_index!(dim)
        @mutex.synchronize do
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
      end

      # Pack a Float array as a FLOAT32 binary string for RediSearch.
      def pack_vector(embedding)
        embedding.map { |v| Float(v) }.pack("f*")
      end

      # Parse the raw FT.SEARCH response into the standard Hash format.
      #
      # Redis FT.SEARCH returns: [count, key1, [field, value, ...], key2, ...]
      def parse_results(raw)
        unless raw.is_a?(Array) && raw.size.odd? && raw.first.is_a?(Integer) &&
            raw.first >= (raw.size - 1) / 2 && raw.first.zero? == (raw.size == 1)
          raise InvalidResultError, "Redis FT.SEARCH requires a count and document/field pairs"
        end

        results = []
        raw.drop(1).each_slice(2) do |key, fields|
          unless key.is_a?(String) && key.start_with?(DOC_PREFIX)
            raise InvalidResultError, "Redis FT.SEARCH returned an invalid document key"
          end
          # Redis documents this null content when a key expires/is updated
          # during the search. The key remains in the total count.
          next if fields.nil?

          field_hash = parse_fields(fields, "FT.SEARCH")
          id = key.delete_prefix(DOC_PREFIX)
          # RediSearch returns cosine distance (0=identical, 2=opposite);
          # convert to cosine similarity for consistency with other backends.
          score = 1.0 - parse_distance(field_hash["score"])
          metadata = parse_metadata(field_hash["metadata"])

          results << {id: id, score: score, metadata: metadata}
        end
        results
      end

      # RESP2 field/value decoding belongs to this backend, not the Contract.
      def parse_fields(raw, command)
        unless raw.is_a?(Array) && raw.size.even?
          raise InvalidResultError, "Redis #{command} requires field/value pairs"
        end
        raw.each_slice(2).each_with_object({}) do |(key, value), fields|
          unless key.is_a?(String) && !fields.key?(key)
            raise InvalidResultError, "Redis #{command} returned an invalid or duplicate field"
          end
          fields[key] = value
        end
      end

      def parse_distance(raw)
        valid = (raw.is_a?(String) && raw.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?\z/)) ||
          (raw.is_a?(Numeric) && raw.real?)
        value = Float(raw, exception: false) if valid
        unless value&.finite?
          raise InvalidResultError, "Redis FT.SEARCH requires a finite numeric score"
        end
        value
      end

      def parse_metadata(raw)
        return {} if raw.nil?
        unless raw.is_a?(String)
          raise InvalidResultError, "Redis metadata must contain a JSON object"
        end
        parsed = JSON.parse(raw, symbolize_names: true)
        unless parsed.is_a?(Hash)
          raise InvalidResultError, "Redis metadata must contain a JSON object"
        end
        parsed
      rescue JSON::ParserError
        raise InvalidResultError, "Redis metadata contains invalid JSON"
      end
    end
  end
end
