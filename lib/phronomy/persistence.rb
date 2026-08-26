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

    # Content-addressed immutable content repository. ContentStore has its own
    # codec/canonicalization boundary and is not wrapped in DurableRecord.
    #
    # @return [Object]
    # @api public
    attr_reader :contents

    # Runtime/domain-facing AgentRoot repository. The backend repository supplied
    # to #initialize is record-oriented; this facade owns encode/decode.
    #
    # @return [Object]
    # @api public
    attr_reader :agents

    # Runtime/domain-facing append-only Agent Journal repository.
    #
    # @return [Object]
    # @api public
    attr_reader :journals

    # Runtime/domain-facing AgentExecution repository.
    #
    # @return [Object]
    # @api public
    attr_reader :executions

    # Runtime/domain-facing durable Workflow snapshot repository.
    #
    # @return [Object]
    # @api public
    attr_reader :workflow_states

    # Initializes a Persistence backend from record-oriented storage
    # repositories.
    #
    # Except for +contents+, backend repositories exchange
    # {Phronomy::Persistence::DurableRecord} values. Phronomy's repository
    # facades own current-format validation and domain-object encode/decode.
    #
    # Identity, revision, admission, and index metadata needed by a Backend is
    # passed explicitly as repository arguments. A Backend must not inspect
    # DurableRecord#payload to rediscover Phronomy domain semantics.
    #
    # Required raw repository shapes:
    # - agents:
    #   create(agent_id:, agent_revision:, record:), load(id),
    #   save(id, expected_revision:, next_revision:, record:), delete(id)
    # - journals:
    #   append(id, expected_position:, records:, record_ids:), read/head/delete
    # - executions:
    #   create_active(execution_id:, agent_id:, execution_revision:, record:),
    #   load(id), save(id, expected_revision:, next_revision:, agent_id:,
    #   active:, record:), list_active/delete/delete_for_agent/assert_idle!
    # - workflow_states:
    #   load(id), save(id, expected_revision:, next_revision:, record:), delete
    #
    # Subclasses normally construct backend-specific raw repository objects and
    # call +super+. Construction fails fast when required capabilities are not
    # advertised.
    #
    # @api public
    def initialize(contents:, agents:, journals:, executions:, workflow_states:)
      @contents = contents
      @agents = RepositoryFacades::Agents.new(agents)
      @journals = RepositoryFacades::Journals.new(journals)
      @executions = RepositoryFacades::Executions.new(executions)
      @workflow_states = RepositoryFacades::WorkflowStates.new(workflow_states)
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
    # The yielded object is a transaction-scoped Persistence view exposing the
    # same domain-facing repository facades. Its underlying backend repositories
    # remain DurableRecord-oriented.
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

    # Backend SPI helper for transaction implementations whose transaction-scoped
    # raw repositories differ from the root repository objects.
    #
    # +watermark+ is a transaction-scoped object responding to
    # +assert_agent_watermark!+. The returned view owns the same Phronomy codec
    # facades as the root Persistence instance, so backend authors never need to
    # instantiate RepositoryFacades directly.
    #
    # Backends whose repository objects are already transaction-scoped may yield
    # +self+ and need not call this helper.
    #
    # @api public
    def build_transaction_view(
      contents:,
      agents:,
      journals:,
      executions:,
      workflow_states:,
      watermark:
    )
      RepositoryFacades::View.new(
        contents: contents,
        agents: agents,
        journals: journals,
        executions: executions,
        workflow_states: workflow_states,
        watermark: watermark
      )
    end

    # Verifies that a live Agent still owns the durable base it hydrated.
    #
    # This is a Backend SPI operation invoked by Phronomy at durable barriers.
    # Ordinary application code should not call it directly. The backend must
    # compare the stored Agent revision and current Journal position against the
    # supplied watermark in the same storage consistency view used by subsequent
    # writes in the surrounding transaction.
    #
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
