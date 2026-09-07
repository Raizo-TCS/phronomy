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

    # Purpose-specific durable Handoff and Team repositories in atomic_all.
    # @api public
    attr_reader :handoff_states, :teams, :team_executions

    # Read-only exact Agent execution result; never creates a live Agent owner.
    # Result is nil until a result_ref exists; errors remain canonical data.
    # @api public
    def execution_result(execution_id)
      assert_observation_thread!
      execution = executions.load(execution_id)
      {
        execution_id: execution.execution_id, agent_id: execution.agent_id,
        status: execution.status, phase: execution.phase,
        result_ref: execution.result_ref, error_ref: execution.error_ref,
        result: execution.result_ref && contents.fetch_text(execution.result_ref),
        error: execution.error_ref && contents.fetch_json(execution.error_ref)
      }.then { |value| Phronomy::Agent::Immutable.copy(value) }
    end

    # Follows one exact Handoff turn without loading any Agent or graph.
    # A committed absent Target reservation remains active; failed reads raise.
    # @api public
    def handoff_result(execution_id, main_agent_id: nil)
      assert_observation_thread!
      anchor = main_agent_id&.to_s
      seen = {}
      current = execution_id.to_s
      reserved_agent_id = nil
      loop do
        raise Phronomy::Persistence::SerializationError, "Cyclic durable Handoff chain" if seen[current]
        seen[current] = true
        begin
          execution = executions.load(current)
        rescue Phronomy::Persistence::NotFoundError
          routing = handoff_states.load(anchor)
          if routing && Array(routing.metadata["cancelled_execution_ids"]).include?(current)
            return {execution_id: current, agent_id: reserved_agent_id, status: :cancelled, result: nil, error: nil}.freeze
          end
          if reserved_agent_id && routing && routing.phase != "stable" && routing.pending_target_execution_id == current
            return {execution_id: current, agent_id: reserved_agent_id, status: :active,
                    phase: :target_pending, reserved: true, result: nil, error: nil}.freeze
          end
          raise
        end
        anchor ||= execution.metadata.dig("coordination", "main_agent_id")
        unless anchor && execution.metadata.dig("coordination", "main_agent_id") == anchor
          raise Phronomy::Persistence::ConflictError, "Execution does not belong to this Handoff anchor"
        end
        return execution_result(current) unless execution.status == :handed_off
        reserved_agent_id = execution.metadata.fetch("handoff_target_agent_id")
        current = execution.metadata.fetch("handoff_target_execution_id")
      end
    end

    # Lists retained active and terminal executions in lexical ID order.
    # after is an exclusive ID cursor; discovery does not imply request dedup.
    # @api public
    def list_executions(agent_id, after: nil, limit: 100)
      assert_observation_thread!
      executions.list(agent_id, after: after, limit: limit)
    end

    # Read-only exact Team result, independent of current Team class/Proc wiring.
    # @api public
    def team_execution_result(team_execution_id)
      assert_observation_thread!
      execution = team_executions.load(team_execution_id)
      {
        team_execution_id: execution.team_execution_id, team_id: execution.team_id,
        status: execution.status, phase: execution.phase,
        result_ref: execution.result_ref, error_ref: execution.error_ref,
        result: execution.result_ref && contents.fetch_json(execution.result_ref),
        error: execution.error_ref && contents.fetch_json(execution.error_ref)
      }.then { |value| Phronomy::Agent::Immutable.copy(value) }
    end

    # Lists retained Team runs; no continuation or callback delivery occurs.
    # @api public
    def list_team_executions(team_id, after: nil, limit: 100)
      assert_observation_thread!
      team_executions.list(team_id, after: after, limit: limit)
    end

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
    def initialize(contents:, agents:, journals:, executions:, workflow_states:, handoff_states:, teams:, team_executions:)
      @contents = contents
      @agents = RepositoryFacades::Agents.new(agents)
      @journals = RepositoryFacades::Journals.new(journals)
      @executions = RepositoryFacades::Executions.new(executions)
      @workflow_states = RepositoryFacades::WorkflowStates.new(workflow_states)
      @handoff_states = RepositoryFacades::HandoffStates.new(handoff_states)
      @teams = RepositoryFacades::Teams.new(teams)
      @team_executions = RepositoryFacades::TeamExecutions.new(team_executions)
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
      handoff_states:, teams:, team_executions:,
      watermark:
    )
      RepositoryFacades::View.new(
        contents: contents,
        agents: agents,
        journals: journals,
        executions: executions,
        workflow_states: workflow_states,
        handoff_states: handoff_states, teams: teams, team_executions: team_executions,
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

    def assert_observation_thread!
      if Phronomy::Runtime.in_event_loop_context?
        raise Phronomy::EventLoopReentrancyError, "Persistence observation cannot block EventLoop"
      end
    end

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
