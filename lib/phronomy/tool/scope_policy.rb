# frozen_string_literal: true

module Phronomy
  module Tool
    # Evaluates whether a tool with a given scope may execute.
    #
    # A ScopePolicy is a callable that receives +(tool_class, scope, agent)+ and
    # returns one of:
    #   +:allow+   — proceed immediately without an approval gate.
    #   +:reject+  — block execution; the tool returns a denial message.
    #   +:approve+ — delegate to the agent's approval handler (if registered);
    #                when no handler is registered the call is rejected.
    #
    # The {Default} instance is used automatically when no custom policy is
    # configured on an agent.
    #
    # @example Custom policy that allows everything
    #   agent.scope_policy = ->(_tool_class, _scope, _agent) { :allow }
    #
    # @example Strict policy that rejects all write scopes
    #   agent.scope_policy = ->(_tc, scope, _agent) {
    #     scope == :write ? :reject : :allow
    #   }
    class ScopePolicy
      # Scopes that must go through an approval gate before execution.
      APPROVAL_REQUIRED_SCOPES = %i[write admin external_network filesystem process external_process].freeze

      # Scopes that are always permitted without approval.
      ALWAYS_ALLOWED_SCOPES = %i[read_only].freeze

      # Returns +:allow+ for always-allowed scopes, +:approve+ for high-risk
      # scopes, and +:allow+ for anything else (including +nil+).
      #
      # @param _tool_class [Class]
      # @param scope [Symbol, nil]
      # @param _agent [Object]
      # @return [:allow, :approve, :reject]
      # @api private
      def call(_tool_class, scope, _agent)
        return :allow if scope.nil? || ALWAYS_ALLOWED_SCOPES.include?(scope)
        return :approve if APPROVAL_REQUIRED_SCOPES.include?(scope)

        :allow
      end

      # Shared singleton used when no custom policy is configured.
      DEFAULT = new.freeze
    end
  end
end
