# frozen_string_literal: true

module Phronomy
  module Storage
    # One synchronous transaction lifetime, independent of physical rollback.
    # @api private
    class Scope
      def initialize
        @thread = Thread.current
        @active = true
        @failed = false
      end

      def check!
        raise TransactionError, "transaction belongs to another execution context" unless @thread.equal?(Thread.current)
        raise TransactionError, "transaction scope is closed" unless @active
        raise TransactionError, "transaction scope has failed; leave it before continuing" if @failed
        true
      end

      def fail! = @failed = true
      def close! = @active = false
    end
  end
end
