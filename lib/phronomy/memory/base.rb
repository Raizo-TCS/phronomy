# frozen_string_literal: true

require_relative "async_capable"

module Phronomy
  module Memory
    class Base
      # Automatically prepend AsyncCapable into every concrete subclass so that
      # save_messages is intercepted regardless of where the subclass defines it.
      def self.inherited(subclass)
        super
        subclass.prepend(Phronomy::Memory::AsyncCapable)
      end

      # @param async [Boolean] when true, +save_messages+ enqueues a background
      #   job via ActiveJob instead of writing synchronously. Requires ActiveJob.
      # @param queue [Symbol, String] ActiveJob queue name used when async: true.
      def initialize(async: false, queue: :default)
        @_async = async
        @_async_queue = queue
      end

      # Load conversation messages for the given thread.
      #
      # @param thread_id    [String]                          identifies the conversation
      # @param token_budget [Phronomy::Context::TokenBudget, nil]
      #                     when provided, implementations should respect
      #                     budget.effective_input_limit when deciding which messages
      #                     to return. When nil, fall back to class-specific defaults.
      # @param query        [String, nil] optional semantic query for retrieval-based memories
      # @return [Array] message-like objects
      def load_messages(thread_id:, token_budget: nil, query: nil, **_options)
        raise NotImplementedError, "#{self.class}#load_messages is not implemented"
      end

      def save_messages(thread_id:, messages:)
        raise NotImplementedError, "#{self.class}#save_messages is not implemented"
      end

      def clear(thread_id:)
        raise NotImplementedError, "#{self.class}#clear is not implemented"
      end
    end
  end
end
