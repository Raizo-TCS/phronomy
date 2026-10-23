# frozen_string_literal: true

module Phronomy
  module Agent
    # Stable domain observation; does not expose repositories or FSM phases.
    # @api public
    ExecutionObservation = Data.define(:agent_id, :execution_id, :status, :result,
      :error, :reservation, :transfer_receipt, :cancellation_requested, :raw_output) do
      def initialize(raw_output: nil, **values)
        super(raw_output: Phronomy::Values::Immutable.copy(raw_output), **values.transform_values { |value| Phronomy::Values::Immutable.copy(value) })
      end

      def self.from_result(value)
        new(agent_id: value.fetch(:agent_id), execution_id: value.fetch(:execution_id), status: value.fetch(:status),
          result: value[:result], raw_output: value[:raw_output], error: value[:error], reservation: nil, transfer_receipt: nil, cancellation_requested: false)
      end

      def absent? = status == :absent
      def terminal? = !%i[absent preparing active suspended].include?(status)
      def continuable? = %i[preparing active].include?(status) && !cancellation_requested
      def active? = %i[preparing active suspended].include?(status)

      def value!
        raise Phronomy::Persistence::NotFoundError, "Execution #{execution_id} is absent" if absent?
        raise RecoverySupport.error_from_failure(error) if error
        to_result
      end

      def to_result
        Phronomy::Values::Immutable.copy(execution_id: execution_id, agent_id: agent_id,
          status: status, result: result, output: result, raw_output: raw_output, error: error)
      end
    end
  end
end
