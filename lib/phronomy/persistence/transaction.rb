# frozen_string_literal: true

module Phronomy
  class Persistence
    # Invalid participation or transaction lifetime; no commit outcome is implied.
    # @api public
    class TransactionError < Error; end

    # Execute short domain operations in one synchronous transaction. Participants
    # bind their own storage adapters; this protocol does not select any domain.
    # Explicit nesting remains a savepoint, never an independent commit.
    # @api public
    def atomic
      scopes = Thread.current.thread_variable_get(:phronomy_persistence_scopes)
      unless scopes
        scopes = {}
        Thread.current.thread_variable_set(:phronomy_persistence_scopes, scopes)
      end
      stack = (scopes[self] ||= [])
      stack.last&.validate!
      if backend.transaction_open? && stack.empty?
        raise TransactionError, "cannot establish commit ownership inside an unrelated storage transaction"
      end
      scope = nil
      result = StorageBoundary.call do
        backend.transaction do |view|
          scope = Transaction.new(self, view, parent: stack.last)
          stack.push(scope)
          begin
            yield scope
          ensure
            scope.close!
            stack.pop
          end
        end
      end
      scope.confirm!
      result
    ensure
      scopes&.delete(self) if stack && stack.empty?
    end

    # A synchronous participation scope. Only storage adapters receive the raw
    # view; domain operations exchange this scope and their own public values.
    # @api public
    class Transaction
      def initialize(persistence, view, parent: nil)
        @persistence, @view, @parent = persistence, view, parent
        @open = true
        @committed = false
        @thread = Thread.current
      end

      # Bind a domain-owned storage adapter to this exact transaction. Exceptions
      # poison this scope even if its caller rescues them inside the outer block.
      # @api public
      def participate(persistence:, adapter:)
        validate!
        unless @persistence.equal?(persistence)
          raise TransactionError, "participation requires the same open Persistence scope"
        end
        StorageBoundary.call do
          @view.atomic { |view| yield adapter.new(view) }
        end
      end

      # A savepoint result is provisional until every enclosing scope commits.
      # @api public
      def committed? = @committed && (!@parent || @parent.committed?)

      # @api private
      def validate!
        unless @open && @thread.equal?(Thread.current)
          raise TransactionError, "participation requires its open synchronous context"
        end
        @view.validate!
      end

      # @api private
      def close! = @open = false
      # @api private
      def confirm! = @committed = true
    end
  end
end
