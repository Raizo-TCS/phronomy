# frozen_string_literal: true

module Phronomy
  module Agent
    # Default in-memory idempotency store for {Checkpoint} resume operations.
    #
    # Tracks consumed checkpoint IDs so that calling {Agent::Base#resume} twice
    # with the same checkpoint raises {Phronomy::CheckpointAlreadyResumedError}
    # instead of silently executing the approved tool a second time.
    #
    # This implementation is *not thread-safe*. It assumes a single agent instance
    # is accessed from only one thread at a time, which is the expected usage pattern.
    # Agent instances themselves are not thread-safe (state like +@messages+, +@config+
    # is not protected), so concurrent calls to the same agent instance are unsupported.
    #
    # Each agent instance gets its own store by default, so no sharing occurs unless
    # the caller explicitly assigns the same store object to multiple agents.
    #
    # For distributed environments (multiple processes or background jobs), swap this
    # for a custom implementation backed by Redis, ActiveRecord, or another shared store.
    # *Your custom store implementation is responsible for ensuring thread-safety* if
    # your application shares the same store instance across multiple threads.
    #
    # @example Plugging in a custom store
    #   agent = MyAgent.new
    #   agent.checkpoint_store = MyRedis::CheckpointStore.new
    #
    # @example Duck-type contract required by any replacement
    #   # consumed?(checkpoint_id) => Boolean
    #   # consume!(checkpoint_id)  => void; raises CheckpointAlreadyResumedError if duplicate
    #
    # @api public
    class CheckpointStore
      def initialize
        @consumed = Set.new
      end

      # Returns +true+ if the given checkpoint ID has already been consumed.
      #
      # @param checkpoint_id [String]
      # @return [Boolean]
      # @api public
      def consumed?(checkpoint_id)
        @consumed.include?(checkpoint_id)
      end

      # Marks +checkpoint_id+ as consumed, or raises if it was already consumed.
      #
      # @param checkpoint_id [String]
      # @raise [Phronomy::CheckpointAlreadyResumedError]
      # @return [void]
      # @api public
      def consume!(checkpoint_id)
        if @consumed.include?(checkpoint_id)
          raise Phronomy::CheckpointAlreadyResumedError,
            "checkpoint #{checkpoint_id} has already been resumed"
        end
        @consumed.add(checkpoint_id)
      end
    end
  end
end
