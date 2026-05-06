# frozen_string_literal: true

require "json"

module Phronomy
  module Checkpointer
    # Redis-backed checkpointer.
    # Persists graph state as a JSON string under the key
    # "phronomy:checkpoint:<thread_id>" in Redis.
    #
    # The Redis client must be compatible with the redis-rb gem interface:
    #   client.set(key, value)
    #   client.get(key)
    #   client.del(key)
    #
    # @example
    #   require "redis"
    #   redis = Redis.new(url: ENV["REDIS_URL"])
    #   checkpointer = Phronomy::Checkpointer::Redis.new(client: redis)
    #   graph.compile(checkpointer: checkpointer)
    #
    # @example with TTL
    #   Phronomy::Checkpointer::Redis.new(client: redis, ttl: 3600)
    class Redis < Base
      KEY_PREFIX = "phronomy:checkpoint:"
      private_constant :KEY_PREFIX

      # @param client  [#set, #get, #del] Redis-compatible client
      # @param ttl     [Integer, nil] optional key expiry in seconds
      def initialize(client:, ttl: nil)
        @client = client
        @ttl = ttl
      end

      # Serializes and stores the checkpoint under the thread's key.
      # @param thread_id [String]
      # @param state     [Object] includes Phronomy::Graph::State
      # @param interrupted_at [Symbol, nil]
      # @param completed_node [Symbol, nil]
      # @return [self]
      def save(thread_id, state, interrupted_at: nil, completed_node: nil)
        json = serialize_state(state)
        # Embed interrupted_at / completed_node alongside state JSON.
        full = JSON.parse(json)
        full["interrupted_at"] = interrupted_at&.to_s
        full["completed_node"] = completed_node&.to_s
        serialized = JSON.generate(full)

        if @ttl
          @client.set(key(thread_id), serialized, ex: @ttl)
        else
          @client.set(key(thread_id), serialized)
        end

        self
      end

      # Loads and deserializes the checkpoint for the given thread_id.
      # @param thread_id [String]
      # @return [Checkpoint, nil]
      def load(thread_id)
        raw = @client.get(key(thread_id))
        return nil unless raw

        state_class, state_data = deserialize_state_data(raw)
        state = state_class.new(**state_data)

        raw_data = JSON.parse(raw)
        Phronomy::Checkpointer::Checkpoint.new(
          state: state,
          interrupted_at: raw_data["interrupted_at"]&.to_sym,
          completed_node: raw_data["completed_node"]&.to_sym
        )
      end

      # Deletes the checkpoint for the given thread_id.
      # @return [self]
      def clear(thread_id)
        @client.del(key(thread_id))
        self
      end

      private

      def key(thread_id)
        "#{KEY_PREFIX}#{thread_id}"
      end
    end
  end
end
