# frozen_string_literal: true

module Phronomy
  class Persistence
    # Content-addressed immutable content repository. ContentStore has its own
    # codec/canonicalization boundary and is not wrapped in DurableRecord.
    #
    # @return [Object]
    # @api public
    def contents = @repositories.contents

    # Runtime/domain-facing AgentRoot repository. The injected backend is
    # record-oriented; this facade owns encode/decode.
    #
    # @return [Object]
    # @api public
    def agents = @repositories.agents

    # Runtime/domain-facing append-only Agent Journal repository.
    #
    # @return [Object]
    # @api public
    def journals = @repositories.journals

    # Runtime/domain-facing AgentExecution repository.
    #
    # @return [Object]
    # @api public
    def executions = @repositories.executions

    # Runtime/domain-facing durable Workflow snapshot repository.
    #
    # @return [Object]
    # @api public
    def workflow_states = @repositories.workflow_states

    # Purpose-specific durable Handoff and Team repositories in atomic_all.
    # @api public
    def handoff_states = @repositories.handoff_states

    # @api public
    def teams = @repositories.teams

    # @api public
    def team_executions = @repositories.team_executions

    # Read-only exact Agent execution result; never creates a live Agent owner.
    # Result is nil until a result_ref exists; errors remain canonical data.
    # @api public
    def execution_result(execution_id)
      assert_observation_thread!
      Phronomy::Agent::Persistence::Queries.new(self).execution_result(execution_id)
    end

    # Follows one exact Handoff turn without constructing a live Agent or graph.
    # A committed absent Target reservation remains active; failed reads raise.
    # @api public
    def handoff_result(execution_id, main_agent_id: nil)
      assert_observation_thread!
      Phronomy::Agent::Persistence::Queries.new(self).handoff_result(execution_id, main_agent_id: main_agent_id)
    end

    # Lists retained active and terminal executions in lexical ID order.
    # after is an exclusive ID cursor; discovery does not imply request dedup.
    # @api public
    def list_executions(agent_id, after: nil, limit: 100)
      assert_observation_thread!
      Phronomy::Agent::Persistence::Queries.new(self).list_executions(agent_id, after: after, limit: limit)
    end

    # Read-only exact Team result, independent of current Team class/Proc wiring.
    # @api public
    def team_execution_result(team_execution_id)
      assert_observation_thread!
      Phronomy::MultiAgent::Persistence::Queries.new(self).team_execution_result(team_execution_id)
    end

    # Lists retained Team runs; no continuation or callback delivery occurs.
    # @api public
    def list_team_executions(team_id, after: nil, limit: 100)
      assert_observation_thread!
      Phronomy::MultiAgent::Persistence::Queries.new(self).list_team_executions(team_id, after: after, limit: limit)
    end

    # The selected raw storage backend, for backend-specific administration.
    # Read and write domain records through the repository accessors above.
    # @api public
    attr_reader :backend

    # Assembles domain repositories over one synchronous storage backend.
    # @api public
    def initialize(backend:)
      Phronomy::Storage::Backend.validate_capabilities!(backend)
      @backend = backend
      @repositories = PersistenceComposition::Repositories.new(backend)
    end

    # Constructs an isolated in-memory storage domain with standard codecs.
    # @api public
    def self.in_memory
      new(backend: Phronomy::Storage::Backends::InMemory.new)
    end

    # @api public
    def capabilities = backend.capabilities

    # Executes a single backend transaction and exposes domain repositories
    # bound to its raw view. Codec and caller failures remain inside the backend
    # block so the backend can roll them back. The block result is returned.
    # Explicit nested calls on this service use savepoint semantics: a failed
    # inner scope rolls back and re-raises; a successful inner scope is committed
    # only with its outer scope. See Storage::Backend#transaction.
    # Storage failures whose commit outcome is fundamentally
    # unknown remain backend/database failures; Phronomy does not claim
    # exactly-once semantics for such failures.
    # @api public
    def transaction
      backend.transaction do |raw_view|
        repositories = raw_view.equal?(backend) ? @repositories : PersistenceComposition::Repositories.new(raw_view)
        yield repositories
      end
    end

    # @api public
    def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
      @repositories.assert_agent_watermark!(
        agent_id: agent_id, agent_revision: agent_revision, journal_position: journal_position
      )
    end

    private

    def assert_observation_thread!
      if Phronomy::Runtime.in_event_loop_context?
        raise Phronomy::EventLoopReentrancyError, "Persistence observation cannot block EventLoop"
      end
    end
  end
end
