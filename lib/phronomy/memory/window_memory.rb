# frozen_string_literal: true

module Phronomy
  module Memory
    # Memory that retains only the most recent k turns (k*2 messages: user + assistant).
    class WindowMemory < Base
      def initialize(k: 10)
        @k = k
        @store = {}
      end

      def load_messages(thread_id:, **)
        (@store[thread_id] || []).last(@k * 2)
      end

      def save_messages(thread_id:, messages:)
        @store[thread_id] = messages
      end

      def clear(thread_id:)
        @store.delete(thread_id)
      end
    end
  end
end
