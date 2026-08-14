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

      class Agents
        def initialize(owner) = @owner = owner

        def create(root)
          @owner.synchronize do
            key = root.agent_id.to_s
            raise ConflictError, "agent_id must not be empty" if key.empty?
            raise ConflictError, "agent already exists: #{key}" if @owner.state[:agents].key?(key)
            @owner.state[:agents][key] = root
          end
          root
        end

        def load(agent_id)
          @owner.synchronize do
            @owner.state[:agents].fetch(agent_id.to_s) { raise NotFoundError, "agent not found: #{agent_id}" }
          end
        end

        def save(agent_id, expected_revision:, root:)
          @owner.synchronize do
            current = @owner.state[:agents].fetch(agent_id.to_s) { raise NotFoundError, "agent not found: #{agent_id}" }
            unless current.agent_revision == expected_revision
              raise ConflictError,
                "agent revision conflict: expected #{expected_revision}, actual #{current.agent_revision}"
            end
            unless root.agent_id.to_s == agent_id.to_s
              raise ConflictError, "Agent root identity mismatch: #{root.agent_id} != #{agent_id}"
            end
            unless root.agent_revision == expected_revision + 1
              raise ConflictError,
                "agent save must advance revision exactly once: " \
                "expected #{expected_revision + 1}, got #{root.agent_revision}"
            end
            @owner.state[:agents][agent_id.to_s] = root
          end
          root
        end

        def delete(agent_id)
          @owner.synchronize { @owner.state[:agents].delete(agent_id.to_s) }
        end
      end

      class Journals
        def initialize(owner) = @owner = owner

        def append(agent_id, expected_position:, records:)
          @owner.synchronize do
            target = (@owner.state[:journals][agent_id.to_s] ||= [])
            unless target.length == expected_position
              raise ConflictError,
                "journal position conflict: expected #{expected_position}, actual #{target.length}"
            end
            existing_ids = target.to_h { |record| [record.record_id, true] }
            incoming_ids = {}
            appended = Array(records).each_with_index.map do |record, index|
              unless record.agent_id.to_s == agent_id.to_s
                raise ConflictError,
                  "Journal record Agent mismatch: #{record.agent_id} != #{agent_id}"
              end
              if existing_ids[record.record_id] || incoming_ids[record.record_id]
                raise ConflictError, "duplicate Journal record_id: #{record.record_id}"
              end
              incoming_ids[record.record_id] = true
              record.with_sequence(expected_position + index + 1)
            end
            target.concat(appended)
            appended.freeze
          end
        end

        def read(agent_id, after: nil, limit: nil)
          @owner.synchronize do
            result = Array(@owner.state[:journals][agent_id.to_s])
            result = result.drop(Integer(after)) if after
            result = result.first(limit) if limit
            result.dup.freeze
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
        def initialize(owner) = @owner = owner

        def create_active(execution)
          @owner.synchronize do
            if @owner.state[:executions].key?(execution.execution_id.to_s)
              raise ConflictError, "execution already exists: #{execution.execution_id}"
            end
            active = @owner.state[:executions].values.find do |candidate|
              candidate.agent_id == execution.agent_id && candidate.active?
            end
            raise Phronomy::AgentBusyError, "agent is busy: #{execution.agent_id}" if active
            @owner.state[:executions][execution.execution_id] = execution
          end
          execution
        end

        def load(execution_id)
          @owner.synchronize do
            @owner.state[:executions].fetch(execution_id.to_s) do
              raise NotFoundError, "execution not found: #{execution_id}"
            end
          end
        end

        def save(execution_id, expected_revision:, execution:)
          @owner.synchronize do
            current = @owner.state[:executions].fetch(execution_id.to_s) { raise NotFoundError, "execution not found: #{execution_id}" }
            unless current.execution_revision == expected_revision
              raise ConflictError,
                "execution revision conflict: expected #{expected_revision}, actual #{current.execution_revision}"
            end
            unless execution.execution_id.to_s == execution_id.to_s
              raise ConflictError,
                "Execution identity mismatch: #{execution.execution_id} != #{execution_id}"
            end
            unless execution.execution_revision == expected_revision + 1
              raise ConflictError,
                "execution save must advance revision exactly once: " \
                "expected #{expected_revision + 1}, got #{execution.execution_revision}"
            end
            @owner.state[:executions][execution_id.to_s] = execution
          end
          execution
        end

        def list_active(agent_id)
          @owner.synchronize do
            @owner.state[:executions].values.select do |execution|
              execution.agent_id == agent_id.to_s && execution.active?
            end.freeze
          end
        end

        def delete(execution_id)
          @owner.synchronize { @owner.state[:executions].delete(execution_id.to_s) }
        end

        def delete_for_agent(agent_id)
          @owner.synchronize do
            @owner.state[:executions].delete_if { |_id, execution| execution.agent_id == agent_id.to_s }
          end
        end

        # Raises AgentBusyError if there is an active execution for agent_id.
        # Must be called from within a transaction (monitor already held).
        def assert_idle!(agent_id)
          active = @owner.state[:executions].values.find do |candidate|
            candidate.agent_id == agent_id.to_s && candidate.active?
          end
          raise Phronomy::AgentBusyError, "agent has an active or suspended execution: #{agent_id}" if active
        end
      end

      class WorkflowStates
        def initialize(owner) = @owner = owner

        def load(thread_id)
          @owner.synchronize do
            record = @owner.workflow_state_data[thread_id.to_s]
            next nil unless record

            {
              snapshot: @owner.deep_dup_workflow_value(record.fetch(:snapshot)),
              revision: record.fetch(:revision)
            }.freeze
          end
        end

        def save(thread_id, expected_revision:, snapshot:)
          @owner.synchronize do
            key = thread_id.to_s
            current = @owner.workflow_state_data[key]
            actual_revision = current&.fetch(:revision)
            unless actual_revision == expected_revision
              raise ConflictError,
                "workflow state revision conflict for #{key}: " \
                "expected #{expected_revision.inspect}, actual #{actual_revision.inspect}"
            end

            next_revision = actual_revision ? actual_revision + 1 : 1
            @owner.workflow_state_data[key] = {
              snapshot: @owner.deep_dup_workflow_value(snapshot),
              revision: next_revision
            }
            next_revision
          end
        end

        def delete(thread_id, expected_revision:)
          @owner.synchronize do
            key = thread_id.to_s
            current = @owner.workflow_state_data[key]
            actual_revision = current&.fetch(:revision)
            unless actual_revision == expected_revision
              raise ConflictError,
                "workflow state revision conflict for #{key}: " \
                "expected #{expected_revision.inspect}, actual #{actual_revision.inspect}"
            end
            @owner.workflow_state_data.delete(key)
          end
          nil
        end
      end

      attr_reader :state, :workflow_state_data

      def initialize
        @monitor = Monitor.new
        @state = {contents: {}, agents: {}, journals: {}, executions: {}}
        @workflow_state_data = {}
        @contents = Contents.new(self)
        @agents = Agents.new(self)
        @journals = Journals.new(self)
        @executions = Executions.new(self)
        @workflow_states = WorkflowStates.new(self)
        super(
          contents: @contents,
          agents: @agents,
          journals: @journals,
          executions: @executions,
          workflow_states: @workflow_states
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

          if stored.agent_revision != agent_revision
            raise ConflictError,
              "agent revision conflict: expected #{agent_revision}, actual #{stored.agent_revision}"
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
          workflow_snapshot = deep_dup_workflow_value(@workflow_state_data)
          begin
            yield self
          rescue
            @state.replace(state_snapshot)
            @workflow_state_data.replace(workflow_snapshot)
            raise
          end
        end
      end

      def synchronize(&block)
        @monitor.synchronize(&block)
      end

      # Workflow fields historically accepted ordinary Ruby values in the
      # in-memory store. Keep that contract without forcing the Agent durable
      # state Marshal snapshot to serialize arbitrary Workflow values.
      def deep_dup_workflow_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[deep_dup_workflow_value(key)] = deep_dup_workflow_value(child)
          end
        when Array
          value.map { |child| deep_dup_workflow_value(child) }
        when NilClass, Symbol, Integer, Float, TrueClass, FalseClass
          value
        else
          return value if value.frozen?

          begin
            value.dup
          rescue TypeError
            value
          end
        end
      end
    end
  end
end
