# frozen_string_literal: true

module Phronomy
  module Memory
    module Storage
      # In-process storage for conversation messages backed by per-thread-id
      # {Phronomy::Actor} instances from {Phronomy::ThreadActorRegistry}.
      # Messages are lost when the process exits.
      #
      # @example
      #   storage = Phronomy::Memory::Storage::InMemory.new
      #   manager = Phronomy::Memory::ConversationManager.new(storage: storage, ...)
      class InMemory < Base
        # Thread-local key for per-thread-id storage data (namespaced by store
        # instance object_id to support multiple independent InMemory stores).
        THREAD_DATA_KEY = :phronomy_storage_in_memory_data

        def initialize
        end

        # -----------------------------------------------------------------------
        # Legacy interface
        # -----------------------------------------------------------------------

        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { (thread_data.store || []).dup }
        end

        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { thread_data.store = messages.dup }
        end

        # @param thread_id [String]
        def clear(thread_id:)
          store_id = object_id
          Phronomy::ThreadActorRegistry.for(thread_id).call do
            (Thread.current[THREAD_DATA_KEY] ||= {}).delete(store_id)
          end
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
          Phronomy::ThreadActorRegistry.for(thread_id).call do
            data = thread_data
            messages.each_with_index do |msg, i|
              seq = starting_seq + i
              data.raw_messages << {seq: seq, message: msg, recorded_at: now}
              data.hwm = [data.hwm, seq].max
            end
          end
        end

        # @param thread_id [String]
        # @return [Integer]
        def next_seq(thread_id:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { thread_data.hwm + 1 }
        end

        # Routes +block+ through the per-thread-id {Phronomy::Actor}, serialising
        # all operations for the same thread.  Reentrant calls (the block itself
        # calling storage methods that also route through the Actor) are safe
        # because {Phronomy::Actor#call} detects the same-thread case and executes
        # inline.
        #
        # @param thread_id [String]
        def with_thread_lock(thread_id:, &block)
          Phronomy::ThreadActorRegistry.for(thread_id).call(&block)
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_raw(thread_id:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { thread_data.raw_messages.dup }
        end

        # @param thread_id [String]
        def clear_raw(thread_id:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { thread_data.raw_messages.clear }
        end

        # -----------------------------------------------------------------------
        # Compaction record interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param start_seq    [Integer]
        # @param end_seq      [Integer]
        # @param summary_text [String]
        def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
          Phronomy::ThreadActorRegistry.for(thread_id).call do
            thread_data.compactions << {start_seq: start_seq, end_seq: end_seq, summary_text: summary_text}
          end
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_compactions(thread_id:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { thread_data.compactions.dup }
        end

        # @param thread_id [String]
        def clear_compactions(thread_id:)
          Phronomy::ThreadActorRegistry.for(thread_id).call { thread_data.compactions.clear }
        end

        # Remove raw messages recorded before +older_than+ for this thread.
        #
        # @param thread_id  [String]
        # @param older_than [Time]
        def purge_older_than(thread_id:, older_than:)
          Phronomy::ThreadActorRegistry.for(thread_id).call do
            thread_data.raw_messages.reject! { |entry| entry[:recorded_at] && entry[:recorded_at] < older_than }
          end
        end

        private

        # Returns (or lazily initialises) the {ThreadData} for the current Actor
        # thread and this storage instance.  Must only be called from within a
        # {Phronomy::ThreadActorRegistry.for} block so that +Thread.current+ is
        # the correct Actor thread.
        def thread_data
          (Thread.current[THREAD_DATA_KEY] ||= {})[object_id] ||= ThreadData.new
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
