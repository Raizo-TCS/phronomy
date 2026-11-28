# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # A saved unsuccessful Target and an unconfirmed parent routing transition.
    # The execution result remains authoritative; this error never changes it.
    # Resolve any original Agent custody, then explicitly resume or cancel the
    # same chain entry to retry only current, guarded routing finalization.
    # @api public
    class HandoffFinalizationError < Phronomy::HandoffError
      attr_reader :main_agent_id, :execution_id, :target_execution_id,
        :execution_result, :execution_error, :finalization_error, :read_error, :disposition

      # execution_id is the requested chain entry, not necessarily its first root.
      # @api public
      def initialize(main_agent_id:, execution_id:, execution_result:, execution_error:, finalization_error:,
        disposition: :not_attempted, read_error: nil)
        unless %i[not_attempted not_committed unknown].include?(disposition)
          raise ArgumentError, "Unsupported Handoff finalization disposition"
        end
        @main_agent_id, @execution_id = main_agent_id.to_s.dup.freeze, execution_id.to_s.dup.freeze
        @execution_result = Phronomy::Values::Immutable.copy(execution_result)
        @target_execution_id = @execution_result.fetch(:execution_id)
        @execution_error = execution_error
        @finalization_error, @read_error, @disposition = finalization_error, read_error, disposition
        saved = @execution_error&.message || "Saved Target status #{@execution_result.fetch(:status)}"
        super("#{saved}; Handoff finalization for #{@target_execution_id.inspect} is #{disposition}: " \
          "#{finalization_error.message}. Resolve original Agent custody if present, then explicitly " \
          "resume or cancel #{@execution_id.inspect}", code: "handoff.finalization_unconfirmed")
      end
    end
  end
end
