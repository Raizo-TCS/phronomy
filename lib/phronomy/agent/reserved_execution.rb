# frozen_string_literal: true

module Phronomy
  module Agent
    # Exact identity reserved by a coordinating domain. Correlation is immutable;
    # mutable routing fences belong to the coordinator, never to this identity.
    # @api public
    ReservedExecution = Data.define(:agent_id, :execution_id, :correlation) do
      def initialize(agent_id:, execution_id:, correlation: nil)
        raise ArgumentError, "reserved identities must not be empty" if agent_id.to_s.empty? || execution_id.to_s.empty?
        super(agent_id: agent_id.to_s.freeze, execution_id: execution_id.to_s.freeze,
              correlation: Phronomy::Values::Immutable.copy(correlation))
      end
    end
  end
end
