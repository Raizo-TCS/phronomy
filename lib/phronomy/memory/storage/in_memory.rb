# frozen_string_literal: true

module Phronomy
  module Memory
    module Storage
      # In-process Hash-backed storage for conversation messages.
      # Messages are lost when the process exits.
      #
      # @example
      #   storage = Phronomy::Memory::Storage::InMemory.new
      #   manager = Phronomy::Memory::ConversationManager.new(storage: storage, ...)
      class InMemory < Base
        def initialize
          @store = {}
          @raw_store = {}       # thread_id => [{seq:, message:}, ...]
          @compaction_store = {} # thread_id => [{start_seq:, end_seq:, summary_text:}, ...]
        end

        # -----------------------------------------------------------------------
        # Legacy interface
        # -----------------------------------------------------------------------

        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          (@store[thread_id] || []).dup
        end

        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          @store[thread_id] = messages.dup
        end

        # @param thread_id [String]
        def clear(thread_id:)
          @store.delete(thread_id)
          clear_raw(thread_id: thread_id)
          clear_compactions(thread_id: thread_id)
        end

        # -----------------------------------------------------------------------
        # Raw message interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param messages     [Array]
        # @param starting_seq [Integer]
        def append_raw(thread_id:, messages:, starting_seq:)
          @raw_store[thread_id] ||= []
          messages.each_with_index do |msg, i|
            @raw_store[thread_id] << {seq: starting_seq + i, message: msg}
          end
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_raw(thread_id:)
          (@raw_store[thread_id] || []).dup
        end

        # @param thread_id [String]
        def clear_raw(thread_id:)
          @raw_store.delete(thread_id)
        end

        # -----------------------------------------------------------------------
        # Compaction record interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param start_seq    [Integer]
        # @param end_seq      [Integer]
        # @param summary_text [String]
        def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
          @compaction_store[thread_id] ||= []
          @compaction_store[thread_id] << {start_seq: start_seq, end_seq: end_seq, summary_text: summary_text}
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_compactions(thread_id:)
          (@compaction_store[thread_id] || []).dup
        end

        # @param thread_id [String]
        def clear_compactions(thread_id:)
          @compaction_store.delete(thread_id)
        end
      end
    end
  end
end
