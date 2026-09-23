# frozen_string_literal: true

module Phronomy
  module Agent
    # Persists initial state and explicit idle-Agent context/lifecycle changes.
    # Base owns live-state publication; execution commits have separate owners.
    # @api private
    class StateWriter
      Update = Data.define(:root, :records)
      private_constant :Update

      def initialize(persistence:, agent_id:)
        @persistence = persistence
        @agent_id = agent_id
      end

      def create_root(definition:, context:, knowledge:, metadata:)
        root = Agent::AgentRoot.create(
          agent_id: agent_id,
          agent_definition_id: definition.fetch(:id),
          agent_definition_version: definition.fetch(:version),
          metadata: metadata
        )
        persistence.transaction do |tx|
          tx.agents.create(root)
          records = initial_context_records(tx: tx, root: root, context: context)
          records.concat(initial_knowledge_records(tx: tx, root: root, knowledge: knowledge))
          unless records.empty?
            appended = tx.journals.append(agent_id, expected_position: 0, records: records)
            root = root.with(
              agent_revision: 1,
              context_revision: 1,
              journal_position: appended.length
            )
            tx.agents.save(agent_id, expected_revision: 0, root: root)
          end
        end
        root
      end

      def add_knowledge(root:, content:, metadata:)
        current = root
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
        Update.new(root: next_root, records: appended)
      end

      def mutate_context(root:, kind:, context_affecting:)
        current = root
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
        Update.new(root: next_root, records: appended)
      end

      private

      attr_reader :persistence, :agent_id

      def initial_context_records(tx:, root:, context:)
        return [] unless context

        imported = context.respond_to?(:records) ? context :
          Agent::ContextImporter.import_messages(context)
        imported.records.map do |record|
          content_ref = case record.content_format
          when :text then tx.contents.put_text(record.content)
          when :json then tx.contents.put_json(record.content)
          else
            raise ArgumentError,
              "unsupported imported content format: #{record.content_format.inspect}"
          end
          Agent::JournalRecord.new(
            agent_id: agent_id,
            kind: record.kind,
            channel: record.channel,
            role: record.role,
            content_ref: content_ref,
            context_generation: root.transcript_generation,
            context_candidate: true,
            metadata: record.metadata
          )
        end
      end

      def initial_knowledge_records(tx:, root:, knowledge:)
        Array(knowledge).map do |content|
          build_knowledge_record(
            tx: tx,
            root: root,
            content: content,
            metadata: {}
          )
        end
      end

      def build_knowledge_record(tx:, root:, content:, metadata:)
        Agent::JournalRecord.new(
          agent_id: agent_id,
          kind: :knowledge,
          channel: :context,
          role: :user,
          content_ref: tx.contents.put_text(String(content)),
          context_generation: root.transcript_generation,
          context_candidate: true,
          metadata: metadata || {}
        )
      end

      def yield_context_revision(current, proposed)
        (proposed.context_revision == current.context_revision) ?
          current.context_revision + 1 : proposed.context_revision
      end
    end
  end
end
