# frozen_string_literal: true

module Phronomy
  # Owns invocation control attachment through the observed result's lifetime.
  # Domain runners carry this operation control, not execution scope internals.
  # @api private
  class InvocationControls
    attr_reader :token

    def self.attach(result, invocation_context:, cancellation_token:)
      controls = new(invocation_context: invocation_context, cancellation_token: cancellation_token)
      controls.bind(result)
      controls
    rescue
      controls&.close
      raise
    end

    def initialize(invocation_context:, cancellation_token:)
      if !invocation_context.nil? && !invocation_context.is_a?(InvocationContext)
        raise TypeError, "invocation_context must be a Phronomy::InvocationContext or nil"
      end
      @scope = invocation_context&.__execution_scope
      @subscriptions = Concurrency::Subscriptions.new
      @token = invocation_context ? Concurrency::CancellationToken.new : cancellation_token
      return unless invocation_context

      [invocation_context.cancellation_token, cancellation_token].compact.uniq.each do |source|
        @subscriptions.cancellation(source) { @token.cancel! }
      end
      if !@scope && invocation_context.deadline
        @subscriptions.after(invocation_context.deadline.remaining_seconds) { @token.cancel! }
      end
      @token.cancel! if @scope && !@scope.__open?
    rescue
      close
      raise
    end

    # Check at the receiving runner, after asynchronous delivery. An already
    # closed scope must not acquire the domain's admission slot or start I/O.
    def check_start!
      if @scope && (!@scope.__open? || @token&.cancelled?)
        raise @scope.__cancellation_error
      end
    end

    def bind(result)
      result.__bind_execution(@scope)
      track(result)
    end

    def track(result)
      @subscriptions.result(result) { close }
      result
    end

    def close
      @subscriptions&.close
    end

    def self.effective_timeout_token(context)
      return context.cancellation_token if context.cancellation_token
      return nil unless context.deadline

      token = Concurrency::CancellationToken.new
      subscriptions = Concurrency::Subscriptions.new
      subscriptions.cancellation(token) { subscriptions.close }
      subscriptions.after(context.deadline.remaining_seconds) { token.cancel! }
      token
    end
  end
end
