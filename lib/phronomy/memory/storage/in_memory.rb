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
          @mutex = Mutex.new
          @store = {}
          @raw_store = {}        # thread_id => [{seq:, message:, recorded_at:}, ...]
          @compaction_store = {} # thread_id => [{start_seq:, end_seq:, summary_text:}, ...]
          @hwm_store = {}        # thread_id => Integer (highest seq ever written; survives purge)
          @actors = {}
          @actors_mutex = Mutex.new
        end

        # -----------------------------------------------------------------------
        # Legacy interface
        # -----------------------------------------------------------------------

        # @param thread_id [String]
        # @return [Array]
        def load(thread_id:)
          @mutex.synchronize { (@store[thread_id] || []).dup }
        end

        # @param thread_id [String]
        # @param messages  [Array]
        def save(thread_id:, messages:)
          @mutex.synchronize { @store[thread_id] = messages.dup }
        end

        # @param thread_id [String]
        def clear(thread_id:)
          @mutex.synchronize do
            @store.delete(thread_id)
            @raw_store.delete(thread_id)
            @compaction_store.delete(thread_id)
            @hwm_store.delete(thread_id)
          end
          @actors_mutex.synchronize { @actors.delete(thread_id)&.stop }
        end

        # -----------------------------------------------------------------------
        # Raw message interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param messages     [Array]
        # @param starting_seq [Integer]
        def append_raw(thread_id:, messages:, starting_seq:)
          now = Time.now
          @mutex.synchronize do
            @raw_store[thread_id] ||= []
            messages.each_with_index do |msg, i|
              seq = starting_seq + i
              @raw_store[thread_id] << {seq: seq, message: msg, recorded_at: now}
              @hwm_store[thread_id] = [@hwm_store[thread_id] || -1, seq].max
            end
          end
        end

        # @param thread_id [String]
        # @return [Integer]
        def next_seq(thread_id:)
          @mutex.synchronize { (@hwm_store[thread_id] || -1) + 1 }
        end

        # Yields while holding the per-thread-id actor's sequential queue.
        # Prevents concurrent compaction records for the same thread.
        # @param thread_id [String]
        def with_thread_lock(thread_id:, &block)
          actor = @actors_mutex.synchronize { @actors[thread_id] ||= Actor.new }
          actor.call(&block)
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_raw(thread_id:)
          @mutex.synchronize { (@raw_store[thread_id] || []).dup }
        end

        # @param thread_id [String]
        def clear_raw(thread_id:)
          @mutex.synchronize { @raw_store.delete(thread_id) }
        end

        # -----------------------------------------------------------------------
        # Compaction record interface
        # -----------------------------------------------------------------------

        # @param thread_id    [String]
        # @param start_seq    [Integer]
        # @param end_seq      [Integer]
        # @param summary_text [String]
        def save_compaction(thread_id:, start_seq:, end_seq:, summary_text:)
          @mutex.synchronize do
            @compaction_store[thread_id] ||= []
            @compaction_store[thread_id] << {start_seq: start_seq, end_seq: end_seq, summary_text: summary_text}
          end
        end

        # @param thread_id [String]
        # @return [Array<Hash>]
        def load_compactions(thread_id:)
          @mutex.synchronize { (@compaction_store[thread_id] || []).dup }
        end

        # @param thread_id [String]
        def clear_compactions(thread_id:)
          @mutex.synchronize { @compaction_store.delete(thread_id) }
        end

        # Remove raw messages recorded before +older_than+ for this thread.
        #
        # @param thread_id  [String]
        # @param older_than [Time]
        def purge_older_than(thread_id:, older_than:)
          @mutex.synchronize do
            next unless @raw_store[thread_id]

            @raw_store[thread_id].reject! { |entry| entry[:recorded_at] && entry[:recorded_at] < older_than }
          end
        end

        private

        # Lightweight synchronous actor: a dedicated Thread drains a Queue,
        # guaranteeing sequential execution of all operations for one thread_id.
        # The calling thread blocks until the actor finishes and re-raises any
        # exception that occurred inside the actor.
        class Actor
          def initialize
            @queue = Queue.new
            @thread = Thread.new do
              loop do
                task = @queue.pop
                break if task == :stop
                task.call
              end
            end
          end

          # Run +block+ on the actor's thread and return its result.
          # Exceptions are captured and re-raised in the caller's thread.
          def call(&block)
            done = Queue.new
            @queue.push(-> {
              begin
                done.push([true, block.call])
              rescue => e
                done.push([false, e])
              end
            })
            success, value = done.pop
            raise value unless success
            value
          end

          # Send a stop sentinel to gracefully terminate the actor's thread.
          def stop
            @queue.push(:stop)
          end
        end
      end
    end
  end
end
