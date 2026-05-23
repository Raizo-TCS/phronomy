# frozen_string_literal: true

module Phronomy
  module StateStore
    # Thread-safe in-process state store backed by a plain Ruby Hash.
    #
    # Used as the recommended default for single-process applications and tests.
    # State does not survive process restart.
    #
    # @example
    #   store = Phronomy::StateStore::InMemory.new
    #   store.save("t1", { fields: { count: 1 }, phase: "__end__" })
    #   store.load("t1")   # => { fields: { count: 1 }, phase: "__end__" }
    #   store.delete("t1")
    #   store.load("t1")   # => nil
    class InMemory < Base
      def initialize
        @data = {}
        @mutex = Mutex.new
      end

      # @param thread_id [String]
      # @return [Hash, nil]
      # @api public
      def load(thread_id)
        @mutex.synchronize do
          snap = @data[thread_id]
          snap ? deep_dup(snap) : nil
        end
      end

      # @param thread_id [String]
      # @param snapshot [Hash]
      # @return [void]
      # @api public
      def save(thread_id, snapshot)
        @mutex.synchronize { @data[thread_id] = deep_dup(snapshot) }
        nil
      end

      # @param thread_id [String]
      # @return [void]
      # @api public
      def delete(thread_id)
        @mutex.synchronize { @data.delete(thread_id) }
        nil
      end

      private

      # Recursively deep-duplicates a plain-data value (Hash, Array, or scalar).
      # Sufficient for snapshot data which consists of JSON-compatible types.
      def deep_dup(val)
        case val
        when Hash then val.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
        when Array then val.map { |v| deep_dup(v) }
        else val.frozen? ? val : (val.dup rescue val) # rubocop:disable Style/RescueModifier
        end
      end
    end
  end
end
