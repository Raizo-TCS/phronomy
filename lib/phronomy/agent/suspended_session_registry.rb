# frozen_string_literal: true

module Phronomy
  module Agent
    # In-process registry for Agent invocations suspended at :awaiting_approval.
    #
    # When an agent invocation halts waiting for human approval, the
    # InvocationContext is stored here keyed by session_id.
    # Agent::Base.approve / Agent::Base.reject look up and remove the context
    # to build a resume session.
    #
    # Thread-safe. Each process has one shared instance via module methods.
    # Cross-process persistence is out of scope (future SessionStore feature).
    #
    # @api private
    module SuspendedSessionRegistry
      @sessions = {}
      @mutex = Mutex.new

      # Stores a suspended context under the given session_id.
      # @param session_id [String]
      # @param ctx [Phronomy::Agent::InvocationContext]
      # @return [void]
      # @api private
      def self.store(session_id, ctx)
        @mutex.synchronize { @sessions[session_id] = ctx }
      end

      # Retrieves and removes the suspended context for session_id.
      # Returns nil when no matching session exists.
      # @param session_id [String]
      # @return [Phronomy::Agent::InvocationContext, nil]
      # @api private
      def self.fetch(session_id)
        @mutex.synchronize { @sessions.delete(session_id) }
      end

      # Returns true when a session is suspended under the given id.
      # @param session_id [String]
      # @return [Boolean]
      # @api private
      def self.exists?(session_id)
        @mutex.synchronize { @sessions.key?(session_id) }
      end

      # Clears all suspended sessions. Intended for test teardown only.
      # @return [void]
      # @api private
      def self.clear!
        @mutex.synchronize { @sessions.clear }
      end
    end
  end
end
