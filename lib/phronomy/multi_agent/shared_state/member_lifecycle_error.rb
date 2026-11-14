# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class SharedState
      # Keeps the member handle when invocation-scoped sharing cannot finish safely.
      # Callers choose approval, cancellation or release through existing Agent APIs.
      # @api public
      class MemberLifecycleError < Phronomy::Error
        # @api public
        attr_reader :agent, :result, :reason, :primary_error, :release_error

        # The live Agent and application resources are process-local, not a
        # durable recipe for rebuilding the sharing provider or its Tools.
        # @api public
        def initialize(agent:, result:, reason:, primary_error: nil, release_error: nil)
          @agent = agent
          @result = result
          @reason = reason
          @primary_error = primary_error
          @release_error = release_error
          message = if reason == :suspended
            "SharedState sharing cannot complete while a member is suspended"
          else
            "SharedState sharing could not release a member: #{release_error&.message}"
          end
          super(message)
        end
      end
    end
  end
end
