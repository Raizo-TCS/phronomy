# frozen_string_literal: true

module Phronomy
  module Memory
    # ConversationManager combines the three independent axes of conversation handling:
    #   - Storage:     where messages are persisted (InMemory, ActiveRecord, ...)
    #   - Retrieval:   which messages to select (Recent, Semantic, ...)
    #   - Compression: how to reduce message size before storage (Summary, ToolOutputPruner, ...)
    #
    # This is the primary entry point for context region 4 (Conversation) in Agent::Base.
    # It replaces the old Memory::WindowMemory / SummaryMemory / etc. monoliths.
    #
    # @example Simple recency-based in-memory manager
    #   manager = Phronomy::Memory::ConversationManager.new(
    #     storage:   Phronomy::Memory::Storage::InMemory.new,
    #     retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 10)
    #   )
    #
    # @example With LLM summary compression
    #   manager = Phronomy::Memory::ConversationManager.new(
    #     storage:     Phronomy::Memory::Storage::InMemory.new,
    #     retrieval:   Phronomy::Memory::Retrieval::Recent.new(k: 5),
    #     compression: Phronomy::Memory::Compression::Summary.new(max_tokens: 4000)
    #   )
    #
    # @example Semantic retrieval with ActiveRecord persistence
    #   manager = Phronomy::Memory::ConversationManager.new(
    #     storage:   Phronomy::Memory::Storage::ActiveRecord.new(model_class: PhronomyMessage),
    #     retrieval: Phronomy::Memory::Retrieval::Semantic.new(embeddings: my_embeddings)
    #   )
    class ConversationManager
      # @param storage     [Memory::Storage::Base]     persistence backend (required)
      # @param retrieval   [Memory::Retrieval::Base]   selection strategy (required)
      # @param compression [Memory::Compression::Base, nil] optional compression strategy
      def initialize(storage:, retrieval:, compression: nil)
        @storage = storage
        @retrieval = retrieval
        @compression = compression
      end

      # Load conversation messages for a thread, applying retrieval selection.
      #
      # @param thread_id [String]
      # @param query     [String, nil] current user input for query-aware retrieval strategies
      # @return [Array]
      def load(thread_id:, query: nil)
        messages = @storage.load(thread_id: thread_id)
        @retrieval.select(messages, query: query)
      end

      # Persist messages for a thread, applying compression before saving.
      # Also updates any retrieval index that requires it (e.g. Semantic).
      #
      # @param thread_id [String]
      # @param messages  [Array]
      def save(thread_id:, messages:)
        to_save = if @compression
          @compression.compress(thread_id: thread_id, messages: messages)
        else
          messages
        end
        @storage.save(thread_id: thread_id, messages: to_save)
        @retrieval.index(thread_id: thread_id, messages: to_save) if @retrieval.respond_to?(:index)
      end

      # Delete all messages for a thread.
      #
      # @param thread_id [String]
      def clear(thread_id:)
        @storage.clear(thread_id: thread_id)
        @retrieval.clear_index(thread_id: thread_id) if @retrieval.respond_to?(:clear_index)
      end
    end
  end
end
