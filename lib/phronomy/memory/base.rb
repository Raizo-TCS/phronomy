# frozen_string_literal: true

module Phronomy
  module Memory
    class Base
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
