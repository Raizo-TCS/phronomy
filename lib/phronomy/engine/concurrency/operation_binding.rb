# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Connects explicit invocation controls before operation admission. Its token
    # is private: cancelling it never cancels the application's shared tokens.
    # Used by Agent, Blocking and Orchestrator admission; it owns no worker.
    # @api private
    class OperationBinding
      attr_reader :token, :scope

      def initialize(invocation_context:, cancellation_token:)
        if !invocation_context.nil? && !invocation_context.is_a?(InvocationContext)
          raise TypeError, "invocation_context must be a Phronomy::InvocationContext or nil"
        end
        @scope = invocation_context&.__execution_scope
        @token = CancellationToken.new
        @subscriptions = Subscriptions.new
        [invocation_context&.cancellation_token, cancellation_token].compact.uniq.each do |source|
          @subscriptions.cancellation(source) { @token.cancel! }
        end
        if !@scope && invocation_context&.deadline
          @subscriptions.after(invocation_context.deadline.remaining_seconds) { @token.cancel! }
        end
        @token.cancel! if @scope && !@scope.__open?
      end

      def bind(result)
        result.__bind_execution(@scope)
        track(result)
      end

      def track(result)
        @subscriptions.result(result) { @subscriptions.close }
        result
      end

      def close
        @subscriptions.close
      end
    end
  end
end
