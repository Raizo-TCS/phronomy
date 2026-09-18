# frozen_string_literal: true

module Phronomy
  module Storage
    # Synchronous record-oriented storage extension contract. Concrete backends
    # implement transactions, capabilities, and watermark checks; domain codecs
    # and repository facades belong to the caller of this contract.
    # @api public
    class Backend < Repositories
      REQUIRED_CAPABILITIES = {
        atomic_all: true,
        atomic_admission: true,
        optimistic_revision: true
      }.freeze

      # @api public
      def initialize(contents:, agents:, journals:, executions:, workflow_states:,
        handoff_states:, teams:, team_executions:)
        super(contents: contents, agents: agents, journals: journals,
              executions: executions, workflow_states: workflow_states,
              handoff_states: handoff_states, teams: teams,
              team_executions: team_executions, watermark: self)
      end

      # Checks capability declarations when a domain-facing service is assembled.
      # A backend may implement the documented protocol without subclassing Backend.
      # @api public
      def self.validate_capabilities!(backend)
        capabilities = backend.capabilities
        missing = REQUIRED_CAPABILITIES.reject { |key, value| capabilities[key] == value }
        return if missing.empty?

        raise UnsupportedBackendError,
          "Persistence backend lacks required capabilities: #{missing.keys.join(", ")}"
      end

      # Declares storage semantics provided by this backend.
      #
      # Required meanings:
      # - +atomic_all+: all durable repositories can participate in one atomic
      #   transaction domain.
      # - +atomic_admission+: Agent execution admission is atomic; at most one
      #   active/suspended execution may be admitted for one Agent. This does not
      #   mean cross-process Workflow admission or distributed locking.
      # - +optimistic_revision+: Agent, Execution, Workflow revision checks and
      #   Journal position checks provide compare-and-swap conflict detection.
      #
      # @return [Hash{Symbol => Boolean}]
      # @api public
      def capabilities
        {
          atomic_all: false,
          atomic_admission: false,
          optimistic_revision: false
        }.freeze
      end

      # Executes one atomic transaction across all eight raw repositories.
      # Yield a Storage::Repositories-compatible view bound to the transaction.
      # Return the block result; raised failures roll back this transaction.
      # Storage failures whose commit outcome is fundamentally
      # unknown remain backend/database failures; Phronomy does not claim
      # exactly-once semantics for such failures.
      # @api public
      def transaction
        raise UnsupportedBackendError, "#{self.class} does not provide atomic_all"
      end

      # Compare Agent revision and Journal position in the same consistency view
      # as subsequent writes. Implementations do not load a live Agent.
      # @api public
      def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
        raise UnsupportedBackendError,
          "#{self.class} does not provide Agent durable-watermark checks"
      end
    end
  end
end
