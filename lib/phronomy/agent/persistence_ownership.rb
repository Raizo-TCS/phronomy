# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Keeps the live Agent instance authoritative for its logical mutable state.
    #
    # Persistence remains the durable representation and recovery source. A
    # loaded Agent hydrates AgentRoot + Journal once, then advances those local
    # values only after successful optimistic Persistence commits.
    #
    # @api private
    module PersistenceOwnership
      module ClassMethods
        def approve(execution_id, approval_request_id:, persistence:, approved: true, config: {})
          approve_async(
            execution_id,
            approval_request_id: approval_request_id,
            persistence: persistence,
            approved: approved,
            config: config
          ).wait_result
        end

        def approve_async(execution_id, approval_request_id:, persistence:, approved: true, config: {})
          activation = Phronomy::Runtime.instance.__agent_activations.fetch(execution_id)
          unless activation
            return failed_approval_task(
              execution_id,
              Phronomy::ExecutionRehydrationRequiredError.new(
                "no live activation for #{execution_id}; durable rehydration is required"
              )
            )
          end

          agent = activation.agent
          unless agent.is_a?(self)
            return failed_approval_task(
              execution_id,
              ArgumentError.new(
                "live activation #{execution_id} belongs to #{agent.class}, not #{self}"
              )
            )
          end

          unless agent.persistence.equal?(persistence)
            return failed_approval_task(
              execution_id,
              ArgumentError.new(
                "live activation #{execution_id} belongs to a different Persistence instance"
              )
            )
          end

          agent.approve_async(
            execution_id,
            approval_request_id: approval_request_id,
            approved: approved,
            config: config
          )
        end

        private

        def failed_approval_task(execution_id, error)
          task = Phronomy::Task.deferred(name: "agent-approval-route:#{execution_id}")
          task.fail(error)
          task
        end
      end

      def initialize(
        agent_id: SecureRandom.uuid,
        context: nil,
        knowledge: [],
        persistence: nil,
        metadata: {},
        load_existing: false
      )
        effective_persistence = persistence || Phronomy.configuration.persistence

        if load_existing
          @persistence = effective_persistence || Phronomy::Persistence::InMemory.new
          @agent_id = agent_id.to_s.freeze
          root = records = nil
          @persistence.transaction do |tx|
            root = tx.agents.load(@agent_id)
            records = tx.journals.read(
              @agent_id,
              limit: root.journal_position
            )
          end
          validate_loaded_definition!(root)
          @root = root
          @_phronomy_journal_records = Array(records).dup.freeze
          return
        end

        super(
          agent_id: agent_id,
          context: context,
          knowledge: knowledge,
          persistence: effective_persistence,
          metadata: metadata,
          load_existing: false
        )
        @_phronomy_journal_records = self.persistence.journals.read(
          self.agent_id,
          limit: agent_root.journal_position
        ).dup.freeze
      end

      def journal_projection
        Agent::JournalProjection.new(
          agent_root: agent_root,
          records: _journal_records_snapshot
        )
      end

      def add_knowledge(content, metadata: {})
        current = agent_root
        next_root = nil
        appended = nil
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
          record = build_knowledge_record(
            tx: tx,
            root: current,
            content: content,
            metadata: metadata
          )
          appended = tx.journals.append(
            agent_id,
            expected_position: current.journal_position,
            records: [record]
          )
          next_root = current.with(
            agent_revision: current.agent_revision + 1,
            context_revision: current.context_revision + 1,
            journal_position: current.journal_position + appended.length
          )
          tx.agents.save(
            agent_id,
            expected_revision: current.agent_revision,
            root: next_root
          )
        end
        _append_journal_records(appended)
        @root = next_root
        self
      end

      def purge!
        result = super
        @_phronomy_journal_records = [].freeze if result
        result
      end

      private

      def validate_loaded_definition!(loaded)
        definition = self.class.agent_definition
        return if loaded.agent_definition_id == definition.fetch(:id) &&
          loaded.definition_version == definition.fetch(:version)

        raise Phronomy::ConfigurationError,
          "Agent definition mismatch for #{@agent_id}: stored " \
          "#{loaded.agent_definition_id}@#{loaded.definition_version}, runtime " \
          "#{definition.fetch(:id)}@#{definition.fetch(:version)}"
      end

      def mutate_context!(kind, context_affecting: true)
        current = agent_root
        next_root = nil
        appended = nil
        persistence.transaction do |tx|
          tx.executions.assert_idle!(agent_id)
          record = Agent::JournalRecord.new(
            agent_id: agent_id,
            kind: kind,
            channel: :state,
            context_generation: current.transcript_generation,
            context_candidate: false
          )
          appended = tx.journals.append(
            agent_id,
            expected_position: current.journal_position,
            records: [record]
          )
          proposed = yield(current)
          next_root = proposed.with(
            journal_position: current.journal_position + appended.length,
            context_revision: context_affecting ?
              yield_context_revision(current, proposed) : current.context_revision
          )
          tx.agents.save(
            agent_id,
            expected_revision: current.agent_revision,
            root: next_root
          )
        end
        _append_journal_records(appended)
        @root = next_root
      end

      def _journal_records_snapshot
        @_phronomy_journal_records || [].freeze
      end

      def _append_journal_records(records)
        incoming = Array(records)
        return _journal_records_snapshot if incoming.empty?

        @_phronomy_journal_records =
          (_journal_records_snapshot + incoming).freeze
      end
    end
  end
end
