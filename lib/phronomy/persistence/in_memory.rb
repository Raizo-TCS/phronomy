# frozen_string_literal: true

require "monitor"
require "digest"

module Phronomy
  class Persistence
    class InMemory < Persistence
      class Contents < Phronomy::ContentStore::Base
        def initialize(owner)
          @owner = owner
        end

        def put(bytes, canonicalization_version:)
          value = String(bytes).b.freeze
          id = content_id_for(value)
          @owner.synchronize do
            current = @owner.state[:contents][id]
            if current && current[:bytes] != value
              raise Phronomy::ContentStore::IntegrityError, "digest collision for #{id}"
            end
            @owner.state[:contents][id] ||= {
              bytes: value,
              canonicalization_version: Integer(canonicalization_version)
            }
          end
          id
        end

        def fetch(content_id)
          @owner.synchronize do
            record = @owner.state[:contents].fetch(content_id.to_s) do
              raise NotFoundError, "content not found: #{content_id}"
            end
            bytes = record[:bytes]
            unless content_id_for(bytes) == content_id.to_s
              raise Phronomy::ContentStore::IntegrityError, "content digest mismatch: #{content_id}"
            end
            bytes.dup
          end
        end

        def exist?(content_id)
          @owner.synchronize { @owner.state[:contents].key?(content_id.to_s) }
        end
      end

      # Backend-side Agent record repository. Values crossing this boundary are
      # DurableRecord objects, never AgentRoot instances.
      class Agents
        def initialize(owner) = @owner = owner

        def create(record)
          record = @owner.require_durable_record!(record)
          @owner.synchronize do
            key = record.payload.fetch("agent_id").to_s
            raise ConflictError, "agent_id must not be empty" if key.empty?
            raise ConflictError, "agent already exists: #{key}" if @owner.state[:agents].key?(key)
            @owner.state[:agents][key] = record.copy
          end
          record.copy
        end

        def load(agent_id)
          @owner.synchronize do
            @owner.state[:agents].fetch(agent_id.to_s) do
              raise NotFoundError, "agent not found: #{agent_id}"
            end.copy
          end
        end

        def save(agent_id, expected_revision:, record:)
          record = @owner.require_durable_record!(record)
          @owner.synchronize do
            current = @owner.state[:agents].fetch(agent_id.to_s) do
              raise NotFoundError, "agent not found: #{agent_id}"
            end
            actual_revision = Integer(current.payload.fetch("agent_revision"))
            unless actual_revision == expected_revision
              raise ConflictError,
                "agent revision conflict: expected #{expected_revision}, actual #{actual_revision}"
            end
            record_agent_id = record.payload.fetch("agent_id").to_s
            unless record_agent_id == agent_id.to_s
              raise ConflictError,
                "Agent root identity mismatch: #{record_agent_id} != #{agent_id}"
            end
            next_revision = Integer(record.payload.fetch("agent_revision"))
            unless next_revision == expected_revision + 1
              raise ConflictError,
                "agent save must advance revision exactly once: " \
                "expected #{expected_revision + 1}, got #{next_revision}"
            end
            @owner.state[:agents][agent_id.to_s] = record.copy
          end
          record.copy
        end

        def delete(agent_id)
          @owner.synchronize { @owner.state[:agents].delete(agent_id.to_s) }
        end
      end

      class Journals
        def initialize(owner) = @owner = owner

        def append(agent_id, expected_position:, records:)
          encoded = Array(records).map { |record| @owner.require_durable_record!(record) }
          @owner.synchronize do
            target = (@owner.state[:journals][agent_id.to_s] ||= [])
            unless target.length == expected_position
              raise ConflictError,
                "journal position conflict: expected #{expected_position}, actual #{target.length}"
            end
            existing_ids = target.to_h do |record|
              [record.payload.fetch("record_id").to_s, true]
            end
            incoming_ids = {}
            encoded.each_with_index do |record, index|
              payload = record.payload
              record_agent_id = payload.fetch("agent_id").to_s
              unless record_agent_id == agent_id.to_s
                raise ConflictError,
                  "Journal record Agent mismatch: #{record_agent_id} != #{agent_id}"
              end
              expected_sequence = expected_position + index + 1
              actual_sequence = Integer(payload.fetch("sequence"))
              unless actual_sequence == expected_sequence
                raise ConflictError,
                  "Journal sequence mismatch: expected #{expected_sequence}, actual #{actual_sequence}"
              end
              record_id = payload.fetch("record_id").to_s
              if existing_ids[record_id] || incoming_ids[record_id]
                raise ConflictError, "duplicate Journal record_id: #{record_id}"
              end
              incoming_ids[record_id] = true
            end
            stored = encoded.map(&:copy)
            target.concat(stored)
            stored.map(&:copy).freeze
          end
        end

        def read(agent_id, after: nil, limit: nil)
          @owner.synchronize do
            result = Array(@owner.state[:journals][agent_id.to_s])
            result = result.drop(Integer(after)) if after
            result = result.first(Integer(limit)) if limit
            result.map(&:copy).freeze
          end
        end

        def head(agent_id)
          @owner.synchronize { Array(@owner.state[:journals][agent_id.to_s]).length }
        end

        def delete(agent_id)
          @owner.synchronize { @owner.state[:journals].delete(agent_id.to_s) }
        end
      end

      class Executions
        ACTIVE_STATUSES = %w[preparing active suspended].freeze

        def initialize(owner) = @owner = owner

        def create_active(record)
          record = @owner.require_durable_record!(record)
          @owner.synchronize do
            payload = record.payload
            execution_id = payload.fetch("execution_id").to_s
            agent_id = payload.fetch("agent_id").to_s
            if @owner.state[:executions].key?(execution_id)
              raise ConflictError, "execution already exists: #{execution_id}"
            end
            active = @owner.state[:executions].values.find do |candidate|
              candidate_payload = candidate.payload
              candidate_payload.fetch("agent_id").to_s == agent_id &&
                ACTIVE_STATUSES.include?(candidate_payload.fetch("status").to_s)
            end
            raise Phronomy::AgentBusyError, "agent is busy: #{agent_id}" if active
            @owner.state[:executions][execution_id] = record.copy
          end
          record.copy
        end

        def load(execution_id)
          @owner.synchronize do
            @owner.state[:executions].fetch(execution_id.to_s) do
              raise NotFoundError, "execution not found: #{execution_id}"
            end.copy
          end
        end

        def save(execution_id, expected_revision:, record:)
          record = @owner.require_durable_record!(record)
          @owner.synchronize do
            current = @owner.state[:executions].fetch(execution_id.to_s) do
              raise NotFoundError, "execution not found: #{execution_id}"
            end
            actual_revision = Integer(current.payload.fetch("execution_revision"))
            unless actual_revision == expected_revision
              raise ConflictError,
                "execution revision conflict: expected #{expected_revision}, actual #{actual_revision}"
            end
            record_execution_id = record.payload.fetch("execution_id").to_s
            unless record_execution_id == execution_id.to_s
              raise ConflictError,
                "Execution identity mismatch: #{record_execution_id} != #{execution_id}"
            end
            next_revision = Integer(record.payload.fetch("execution_revision"))
            unless next_revision == expected_revision + 1
              raise ConflictError,
                "execution save must advance revision exactly once: " \
                "expected #{expected_revision + 1}, got #{next_revision}"
            end
            @owner.state[:executions][execution_id.to_s] = record.copy
          end
          record.copy
        end

        def list_active(agent_id)
          @owner.synchronize do
            @owner.state[:executions].values.select do |record|
              payload = record.payload
              payload.fetch("agent_id").to_s == agent_id.to_s &&
                ACTIVE_STATUSES.include?(payload.fetch("status").to_s)
            end.map(&:copy).freeze
          end
        end

        def delete(execution_id)
          @owner.synchronize { @owner.state[:executions].delete(execution_id.to_s) }
        end

        def delete_for_agent(agent_id)
          @owner.synchronize do
            @owner.state[:executions].delete_if do |_id, record|
              record.payload.fetch("agent_id").to_s == agent_id.to_s
            end
          end
        end

        def assert_idle!(agent_id)
          active = @owner.state[:executions].values.find do |record|
            payload = record.payload
            payload.fetch("agent_id").to_s == agent_id.to_s &&
              ACTIVE_STATUSES.include?(payload.fetch("status").to_s)
          end
          if active
            raise Phronomy::AgentBusyError,
              "agent has an active or suspended execution: #{agent_id}"
          end
        end
      end

      class WorkflowStates
        def initialize(owner) = @owner = owner

        def load(workflow_instance_id)
          @owner.synchronize do
            record = @owner.state[:workflow_states][workflow_instance_id.to_s]
            record&.copy
          end
        end

        def save(workflow_instance_id, expected_revision:, record:)
          record = @owner.require_durable_record!(record)
          @owner.synchronize do
            key = workflow_instance_id.to_s
            current = @owner.state[:workflow_states][key]
            actual_revision = current&.payload&.fetch("workflow_revision")
            unless actual_revision == expected_revision
              raise ConflictError,
                "workflow state revision conflict for #{key}: " \
                "expected #{expected_revision.inspect}, actual #{actual_revision.inspect}"
            end

            payload = record.payload
            unless payload.fetch("workflow_instance_id").to_s == key
              raise ConflictError,
                "Workflow state identity mismatch: " \
                "#{payload.fetch("workflow_instance_id")} != #{key}"
            end
            expected_next = expected_revision.nil? ? 1 : expected_revision + 1
            actual_next = Integer(payload.fetch("workflow_revision"))
            unless actual_next == expected_next
              raise ConflictError,
                "workflow state save must advance revision exactly once: " \
                "expected #{expected_next}, got #{actual_next}"
            end

            @owner.state[:workflow_states][key] = record.copy
          end
          record.copy
        end

        def delete(workflow_instance_id, expected_revision:)
          @owner.synchronize do
            key = workflow_instance_id.to_s
            current = @owner.state[:workflow_states][key]
            actual_revision = current&.payload&.fetch("workflow_revision")
            unless actual_revision == expected_revision
              raise ConflictError,
                "workflow state revision conflict for #{key}: " \
                "expected #{expected_revision.inspect}, actual #{actual_revision.inspect}"
            end
            @owner.state[:workflow_states].delete(key)
          end
          nil
        end
      end

      attr_reader :state

      def initialize
        @monitor = Monitor.new
        @state = {
          contents: {},
          agents: {},
          journals: {},
          executions: {},
          workflow_states: {}
        }
        @contents_backend = Contents.new(self)
        @agents_backend = Agents.new(self)
        @journals_backend = Journals.new(self)
        @executions_backend = Executions.new(self)
        @workflow_states_backend = WorkflowStates.new(self)
        super(
          contents: @contents_backend,
          agents: @agents_backend,
          journals: @journals_backend,
          executions: @executions_backend,
          workflow_states: @workflow_states_backend
        )
      end

      def capabilities
        {atomic_all: true, atomic_admission: true, optimistic_revision: true}.freeze
      end

      def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
        synchronize do
          stored = @state[:agents][agent_id.to_s]
          unless stored
            raise NotFoundError, "Agent not found: #{agent_id}"
          end

          actual_revision = Integer(stored.payload.fetch("agent_revision"))
          if actual_revision != agent_revision
            raise ConflictError,
              "agent revision conflict: expected #{agent_revision}, actual #{actual_revision}"
          end

          actual_position = Array(@state[:journals][agent_id.to_s]).length
          if actual_position != journal_position
            raise ConflictError,
              "journal position conflict: expected #{journal_position}, actual #{actual_position}"
          end

          true
        end
      end

      def transaction
        synchronize do
          state_snapshot = Marshal.load(Marshal.dump(@state))
          begin
            yield self
          rescue
            @state.replace(state_snapshot)
            raise
          end
        end
      end

      def synchronize(&block)
        @monitor.synchronize(&block)
      end

      # @api private
      def require_durable_record!(record)
        return record if record.is_a?(Phronomy::Persistence::DurableRecord)

        raise Phronomy::Persistence::SerializationError,
          "backend repository expected Persistence::DurableRecord, got #{record.class}"
      end
    end
  end
end
