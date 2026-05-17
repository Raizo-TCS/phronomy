# frozen_string_literal: true

module Phronomy
  module Memory
    module Storage
      # In-process storage for conversation messages.
      # Data is held in an instance-level Hash keyed by +thread_id+.
      # Not thread-safe for concurrent writes to the same +thread_id+.
      # For production use prefer a persistent backend such as
      # {Phronomy::Memory::Storage::ActiveRecord}.
      #
      # @example
      #   storage = Phronomy::Memory::Storage::InMemory.new
      #   manager = Phronomy::Memory::ConversationManager.new(storage: storage, ...)
      class InMemory < Base
        def initialize
          @data = {}
          @mutexes = {}
          @registry_mutex = Mutex.new
        end

        # -----------------------------------------------------------------------
        # Legacy interface
        # -----------------------------------------------------------------------

        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          (thread_data_for(thread_id).store || []).dup
        end

        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          thread_data_for(thread_id).store = messages.dup
        end

        # @param thread_id [String]
        def clear(thread_id:)
          @data.delete(thread_id)
        end

        # -----------------------------------------------------------------------
        # Raw message interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param messages     [Array]
        # @param starting_seq [Integer]
        # @param recorded_at  [Time, nil] timestamp for test overrides; defaults to +Time.now+
        def append_raw(thread_id:, messages:, starting_seq:, recorded_at: nil)
          now = recorded_at || Time.now
          data = thread_data_for(thread_id)
          messages.each_with_index do |msg, i|
            seq = starting_seq + i
            data.raw_messages << {seq: seq, message: msg, recorded_at: now}
            data.hwm = [data.hwm, seq].max
          end
        end

        # @param thread_id [String]
        # @return [Integer]
        def next_seq(thread_id:)
          thread_data_for(thread_id).hwm + 1
        end

        # Serializes operations for the given +thread_id+ using a per-thread-id Mutex.
        # Prevents concurrent compaction attempts from producing overlapping records.
        #
        # @param thread_id [String]
        def with_thread_lock(thread_id:)
          mutex = @registry_mutex.synchronize { @mutexes[thread_id] ||= Mutex.new }
          mutex.synchronize { yield }
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_raw(thread_id:)
          thread_data_for(thread_id).raw_messages.dup
        end

        # @param thread_id [String]
        def clear_raw(thread_id:)
          thread_data_for(thread_id).raw_messages.clear
        end

        # -----------------------------------------------------------------------
        # Compaction record interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param start_seq    [Integer]
        # @param end_seq      [Integer]
        # @param summary_text [String]
        def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
          thread_data_for(thread_id).compactions << {start_seq: start_seq, end_seq: end_seq, summary_text: summary_text}
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_compactions(thread_id:)
          thread_data_for(thread_id).compactions.dup
        end

        # @param thread_id [String]
        def clear_compactions(thread_id:)
          thread_data_for(thread_id).compactions.clear
        end

        # Remove raw messages recorded before +older_than+ for this thread.
        #
        # @param thread_id  [String]
        # @param older_than [Time]
        def purge_older_than(thread_id:, older_than:)
          thread_data_for(thread_id).raw_messages.reject! { |entry| entry[:recorded_at] && entry[:recorded_at] < older_than }
        end

        private

        # Returns (or lazily initialises) the {ThreadData} for +thread_id+.
        def thread_data_for(thread_id)
          @data[thread_id] ||= ThreadData.new
        end

        # Value object holding all per-thread-id storage state.
        class ThreadData
          attr_accessor :store, :raw_messages, :compactions, :hwm

          def initialize
            @store = nil
            @raw_messages = []
            @compactions = []
            @hwm = -1
          end
        end
      end
    end
  end
end
