# frozen_string_literal: true

module Phronomy
  module Agent
    # Successful application work with one or more failed Agent releases.
    # Original exceptions and the successful result remain available to the caller.
    # @api public
    class ScopeCleanupError < Phronomy::Error
      attr_reader :failures, :result

      def initialize(failures:, result:)
        @failures = failures.map { |failure| failure.dup.freeze }.freeze
        @result = result
        super("Agent scope cleanup failed for: #{@failures.map { |f| f.fetch(:agent_id) }.join(", ")}",
          code: "agent.scope_cleanup_failed")
      end
    end
  end
end
