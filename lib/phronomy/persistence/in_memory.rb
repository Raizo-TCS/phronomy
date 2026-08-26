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

      # Backend-side Agent record repository. DurableRecord is opaque here;
      # identity/revision metadata is supplied explicitly by RepositoryFacades.
      class Agents
        def initialize(owner) = @owner = owner

        def create(agent_id:, agent_revision:, record:)
          record = @owner.require_durable_record!(record)
          key = agent_id.to_s
          revision = Integer(agent_revision)
          raise ConflictError, "agent_id must not be empty" if key.empty?
          raise ConflictError, "agent_revision must be non-negative" if revision.negative?

          @owner.synchronize do
            raise ConflictError, "agent already exists: #{key}" if @owner.state[:agents].key?(key)
            @owner.state[:agents][key] = record.copy
            @owner.state[:agent_revisions][key] = revision
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

        def save(agent_id, expected_revision:, next_revision:, record:)
          record = @owner.require_durable_record!(record)
          key = agent_id.to_s
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          @owner.synchronize do
            unless @owner.state[:agents].key?(key)
              raise NotFoundError, "agent not found: #{agent_id}"
            end
            actual_revision = @owner.state[:agent_revisions].fetch(key)
            unless actual_revision == expected
              raise ConflictError,
                "agent revision conflict: expected #{expected}, actual #{actual_revision}"
            end
            unless next_value == expected + 1
              raise ConflictError,
                "agent save must advance revision exactly once: " \
                "expected #{expected + 1}, got #{next_value}"
            end
            @owner.state[:agents][key] = record.copy
            @owner.state[:agent_revisions][key] = next_value
          end
          record.copy
        end

        def delete(agent_id)
          @owner.synchronize do
            key = agent_id.to_s
            @owner.state[:agent_revisions].delete(key)
            @owner.state[:agents].delete(key)
          end
        end
      end

      class Journals
        def initialize(owner) = @owner = owner

        def append(agent_id, expected_position:, records:, record_ids:)
          encoded = Array(records).map { |record| @owner.require_durable_record!(record) }
          ids = Array(record_ids).map(&:to_s)
          unless encoded.length == ids.length
            raise ConflictError,
              "Journal records/record_ids length mismatch: #{encoded.length} != #{ids.length}"
          end
          if ids.any?(&:empty?)
            raise ConflictError, "Journal record_id must not be empty"
          end

          @owner.synchronize do
            key = agent_id.to_s
            target = (@owner.state[:journals][key] ||= [])
            known_ids = (@owner.state[:journal_record_ids][key] ||= {})
            expected = Integer(expected_position)
            unless target.length == expected
              raise ConflictError,
                "journal position conflict: expected #{expected}, actual #{target.length}"
            end

            incoming_ids = {}
            ids.each do |record_id|
              if known_ids[record_id] || incoming_ids[record_id]
                raise ConflictError, "duplicate Journal record_id: #{record_id}"
              end
              incoming_ids[record_id] = true
            end

            stored = encoded.map(&:copy)
            target.concat(stored)
            incoming_ids.each_key { |record_id| known_ids[record_id] = true }
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
          @owner.synchronize do
            key = agent_id.to_s
            @owner.state[:journal_record_ids].delete(key)
            @owner.state[:journals].delete(key)
          end
        end
      end

      class Executions
        def initialize(owner) = @owner = owner

        def create_active(execution_id:, agent_id:, execution_revision:, record:)
          record = @owner.require_durable_record!(record)
          execution_key = execution_id.to_s
          agent_key = agent_id.to_s
          revision = Integer(execution_revision)
          raise ConflictError, "execution_id must not be empty" if execution_key.empty?
          raise ConflictError, "agent_id must not be empty" if agent_key.empty?
          raise ConflictError, "execution_revision must be non-negative" if revision.negative?

          @owner.synchronize do
            if @owner.state[:executions].key?(execution_key)
              raise ConflictError, "execution already exists: #{execution_key}"
            end
            active = @owner.state[:execution_metadata].values.find do |metadata|
              metadata.fetch(:agent_id) == agent_key && metadata.fetch(:active)
            end
            raise Phronomy::AgentBusyError, "agent is busy: #{agent_key}" if active

            @owner.state[:executions][execution_key] = record.copy
            @owner.state[:execution_metadata][execution_key] = {
              agent_id: agent_key,
              revision: revision,
              active: true
            }.freeze
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

        def save(execution_id, expected_revision:, next_revision:, agent_id:, active:, record:)
          record = @owner.require_durable_record!(record)
          execution_key = execution_id.to_s
          agent_key = agent_id.to_s
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          unless active.equal?(true) || active.equal?(false)
            raise ConflictError, "execution active metadata must be true or false"
          end

          @owner.synchronize do
            unless @owner.state[:executions].key?(execution_key)
              raise NotFoundError, "execution not found: #{execution_id}"
            end
            current = @owner.state[:execution_metadata].fetch(execution_key)
            actual_revision = current.fetch(:revision)
            unless actual_revision == expected
              raise ConflictError,
                "execution revision conflict: expected #{expected}, actual #{actual_revision}"
            end
            unless current.fetch(:agent_id) == agent_key
              raise ConflictError,
                "Execution Agent identity mismatch: #{agent_key} != #{current.fetch(:agent_id)}"
            end
            unless next_value == expected + 1
              raise ConflictError,
                "execution save must advance revision exactly once: " \
                "expected #{expected + 1}, got #{next_value}"
            end

            @owner.state[:executions][execution_key] = record.copy
            @owner.state[:execution_metadata][execution_key] = {
              agent_id: agent_key,
              revision: next_value,
              active: active
            }.freeze
          end
          record.copy
        end

        def list_active(agent_id)
          @owner.synchronize do
            agent_key = agent_id.to_s
            ids = @owner.state[:execution_metadata].filter_map do |execution_id, metadata|
              execution_id if metadata.fetch(:agent_id) == agent_key && metadata.fetch(:active)
            end
            ids.map { |execution_id| @owner.state[:executions].fetch(execution_id).copy }.freeze
          end
        end

        def delete(execution_id)
          @owner.synchronize do
            key = execution_id.to_s
            @owner.state[:execution_metadata].delete(key)
            @owner.state[:executions].delete(key)
          end
        end

        def delete_for_agent(agent_id)
          @owner.synchronize do
            agent_key = agent_id.to_s
            ids = @owner.state[:execution_metadata].filter_map do |execution_id, metadata|
              execution_id if metadata.fetch(:agent_id) == agent_key
            end
            ids.each do |execution_id|
              @owner.state[:execution_metadata].delete(execution_id)
              @owner.state[:executions].delete(execution_id)
            end
          end
        end

        def assert_idle!(agent_id)
          @owner.synchronize do
            active = @owner.state[:execution_metadata].values.find do |metadata|
              metadata.fetch(:agent_id) == agent_id.to_s && metadata.fetch(:active)
            end
            if active
              raise Phronomy::AgentBusyError,
                "agent has an active or suspended execution: #{agent_id}"
            end
          end
          true
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

        def save(workflow_instance_id, expected_revision:, next_revision:, record:)
          record = @owner.require_durable_record!(record)
          key = workflow_instance_id.to_s
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          next_value = Integer(next_revision)
          @owner.synchronize do
            actual_revision = @owner.state[:workflow_revisions][key]
            unless actual_revision == expected
              raise ConflictError,
                "workflow state revision conflict for #{key}: " \
                "expected #{expected.inspect}, actual #{actual_revision.inspect}"
            end
            expected_next = expected.nil? ? 1 : expected + 1
            unless next_value == expected_next
              raise ConflictError,
                "workflow state save must advance revision exactly once: " \
                "expected #{expected_next}, got #{next_value}"
            end

            @owner.state[:workflow_states][key] = record.copy
            @owner.state[:workflow_revisions][key] = next_value
          end
          record.copy
        end

        def delete(workflow_instance_id, expected_revision:)
          @owner.synchronize do
            key = workflow_instance_id.to_s
            expected = Integer(expected_revision)
            actual_revision = @owner.state[:workflow_revisions][key]
            unless actual_revision == expected
              raise ConflictError,
                "workflow state revision conflict for #{key}: " \
                "expected #{expected.inspect}, actual #{actual_revision.inspect}"
            end
            @owner.state[:workflow_revisions].delete(key)
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
          agent_revisions: {},
          journals: {},
          journal_record_ids: {},
          executions: {},
          execution_metadata: {},
          workflow_states: {},
          workflow_revisions: {}
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
          key = agent_id.to_s
          unless @state[:agents].key?(key)
            raise NotFoundError, "Agent not found: #{agent_id}"
          end

          actual_revision = @state[:agent_revisions].fetch(key)
          if actual_revision != agent_revision
            raise ConflictError,
              "agent revision conflict: expected #{agent_revision}, actual #{actual_revision}"
          end

          actual_position = Array(@state[:journals][key]).length
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
