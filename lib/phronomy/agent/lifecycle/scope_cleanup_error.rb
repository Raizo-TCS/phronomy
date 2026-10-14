# frozen_string_literal: true

module Phronomy
  module Agent
    # Successful application work with one or more failed Agent releases.
    # Original exceptions and the successful result remain available to the caller.
    # @api public
    class ScopeCleanupError < Phronomy::Error
      attr_reader :failures, :result, :primary_error, :scope

      def initialize(scope:, failures:, result: nil, primary_error: nil)
        @failures = failures.map { |failure| failure.dup.freeze }.freeze
        @result = result
        @primary_error = primary_error
        @scope = scope
        super("Agent scope cleanup failed for: #{@failures.map { |f| f.fetch(:agent_id) }.join(", ")}",
          code: "agent.scope_cleanup_failed")
      end
    end
  end
end
