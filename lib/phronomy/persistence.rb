# frozen_string_literal: true

module Phronomy
  class Persistence
    class ConflictError < Phronomy::Error; end
    class NotFoundError < Phronomy::Error; end
    class UnsupportedBackendError < Phronomy::Error; end
    class SerializationError < Phronomy::Error; end

    REQUIRED_CAPABILITIES = {
      atomic_all: true,
      atomic_admission: true,
      optimistic_revision: true
    }.freeze

    # Durable repository accessors supplied by a Persistence backend.
    #
    # The repository objects are part of the Backend SPI. They may be private
    # implementation classes owned by the backend; they do not need to inherit
    # from Phronomy repository base classes.
    #
    # @return [Object] content-addressed immutable content repository
    # @api public
    attr_reader :contents

    # @return [Object] AgentRoot repository
    # @api public
    attr_reader :agents

    # @return [Object] append-only Agent Journal repository
    # @api public
    attr_reader :journals

    # @return [Object] AgentExecution repository
    # @api public
    attr_reader :executions

    # @return [Object] durable Workflow snapshot repository
    # @api public
    attr_reader :workflow_states

    # Initializes a Persistence backend with its durable repositories.
    #
    # Subclasses normally construct backend-specific repository objects and then
    # call +super+. The backend must advertise every capability in
    # {REQUIRED_CAPABILITIES}; construction fails fast otherwise.
    #
    # @param contents [Object]
    # @param agents [Object]
    # @param journals [Object]
    # @param executions [Object]
    # @param workflow_states [Object]
    # @raise [UnsupportedBackendError] when a required capability is missing
    # @api public
    def initialize(contents:, agents:, journals:, executions:, workflow_states:)
      @contents = contents
      @agents = agents
      @journals = journals
      @executions = executions
      @workflow_states = workflow_states
      validate_capabilities!
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

    # Executes one atomic durable transaction.
    #
    # The object yielded to the block is a transaction-scoped Persistence view.
    # It must respond to +contents+, +agents+, +journals+, +executions+,
    # +workflow_states+, and +assert_agent_watermark!+. It may be +self+, but
    # backends are free to yield a separate transaction view backed by a checked
    # out connection/session.
    #
    # If the block raises, mutations made through the transaction view must not
    # be committed. Storage failures whose commit outcome is fundamentally
    # unknown remain backend/database failures; Phronomy does not claim
    # exactly-once semantics for such failures.
    #
    # @yieldparam transaction_view [Object]
    # @return [Object] the block result
    # @raise [UnsupportedBackendError] when atomic transactions are unavailable
    # @api public
    def transaction
      raise UnsupportedBackendError, "#{self.class} does not provide atomic_all"
    end

    # Verifies that a live Agent still owns the durable base it hydrated.
    #
    # This is a Backend SPI operation invoked by Phronomy at durable barriers.
    # Ordinary application code should not call it directly. The backend must
    # compare the stored Agent revision and current Journal position against the
    # supplied watermark in the same storage consistency view used by subsequent
    # writes in the surrounding transaction.
    #
    # The method is a precondition check only. It must not reload or return
    # replacement mutable Agent state; the live Agent remains the logical owner.
    #
    # @param agent_id [String]
    # @param agent_revision [Integer]
    # @param journal_position [Integer]
    # @return [true]
    # @raise [NotFoundError] when the Agent does not exist
    # @raise [ConflictError] when either durable watermark component differs
    # @raise [UnsupportedBackendError] when the backend does not implement the check
    # @api public
    def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
      raise UnsupportedBackendError,
        "#{self.class} does not provide Agent durable-watermark checks"
    end

    private

    def validate_capabilities!
      missing = REQUIRED_CAPABILITIES.reject do |key, value|
        capabilities[key] == value
      end
      return if missing.empty?

      raise UnsupportedBackendError,
        "Persistence backend lacks required capabilities: #{missing.keys.join(", ")}"
    end
  end
end
