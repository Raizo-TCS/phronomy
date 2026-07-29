# frozen_string_literal: true

module Phronomy
  module Agent
    # In-process registry for suspended AgentInvocation aggregates.
    #
    # The registry is the single in-process source for pending Human approval.
    # Cross-process persistence remains outside the scope of this implementation.
    #
    # @api private
    module AgentInvocationRegistry
      Entry = Struct.new(:invocation, :approval_request)

      @entries = {}
      @approval_index = {}
      @mutex = Mutex.new

      def self.store_suspended(invocation, approval_request)
        @mutex.synchronize do
          invocation_id = invocation.id
          request_id = approval_request.id
          if @entries.key?(invocation_id) || @approval_index.key?(request_id)
            raise Phronomy::Error,
              "Suspended AgentInvocation is already registered: #{invocation_id}"
          end

          @entries[invocation_id] = Entry.new(
            invocation: invocation,
            approval_request: approval_request
          )
          @approval_index[request_id] = invocation_id
        end
        approval_request
      end

      # Atomically removes and returns one pending approval aggregate.
      # Duplicate approval commands therefore cannot execute the Tool twice.
      def self.consume_approval(agent_invocation_id, approval_request_id)
        @mutex.synchronize do
          indexed_invocation_id = @approval_index[approval_request_id.to_s]
          return nil unless indexed_invocation_id == agent_invocation_id.to_s

          entry = @entries.delete(indexed_invocation_id)
          return nil unless entry

          @approval_index.delete(entry.approval_request.id)
          entry
        end
      end

      def self.lookup(agent_invocation_id)
        @mutex.synchronize { @entries[agent_invocation_id.to_s] }
      end

      def self.exists?(agent_invocation_id)
        @mutex.synchronize { @entries.key?(agent_invocation_id.to_s) }
      end

      def self.remove_terminal(agent_invocation_id)
        @mutex.synchronize do
          entry = @entries.delete(agent_invocation_id.to_s)
          @approval_index.delete(entry.approval_request.id) if entry
          entry
        end
      end

      def self.clear!
        @mutex.synchronize do
          @entries.clear
          @approval_index.clear
        end
      end
    end
  end
end
