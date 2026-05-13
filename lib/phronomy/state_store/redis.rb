# frozen_string_literal: true

require "json"

module Phronomy
  module StateStore
    # Redis-backed state store.
    # Persists graph state as a JSON string under the key
    # "phronomy:state:<thread_id>" in Redis.
    #
    # The Redis client must be compatible with the redis-rb gem interface:
    #   client.set(key, value)
    #   client.get(key)
    #   client.del(key)
    #
    # @example
    #   require "redis"
    #   redis = Redis.new(url: ENV["REDIS_URL"])
    #   Phronomy.configure do |c|
    #     c.default_state_store = Phronomy::StateStore::Redis.new(client: redis)
    #   end
    #
    # @example with TTL
    #   Phronomy::StateStore::Redis.new(client: redis, ttl: 3600)
    class Redis < Base
      KEY_PREFIX = "phronomy:state:"
      private_constant :KEY_PREFIX

      # @param client [#set, #get, #del] Redis-compatible client
      # @param ttl    [Integer, nil] optional key expiry in seconds
      def initialize(client:, ttl: nil)
        @client = client
        @ttl = ttl
      end

      # @param state [Object] includes Phronomy::WorkflowContext
      # @return [self]
      def save(state)
        serialized = serialize_state(state)
        if @ttl
          @client.set(key(state.thread_id), serialized, ex: @ttl)
        else
          @client.set(key(state.thread_id), serialized)
        end
        self
      end

      # @param thread_id [String]
      # @return [Object, nil] state instance or nil
      def load(thread_id)
        raw = @client.get(key(thread_id))
        return nil unless raw

        deserialize_state(raw)
      end

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
