# frozen_string_literal: true

require "securerandom"
require "time"

module Phronomy
  module Agent
    class AgentExecution
      ACTIVE_STATUSES = %i[preparing active suspended].freeze
      TERMINAL_STATUSES = %i[completed handed_off failed cancelled rejected blocked].freeze
      TRANSITIONS = {
        preparing: %i[preparing active failed cancelled blocked],
        active: %i[active suspended completed handed_off failed cancelled rejected blocked],
        suspended: %i[suspended active failed cancelled],
        completed: %i[completed],
        handed_off: %i[handed_off],
        failed: %i[failed],
        cancelled: %i[cancelled],
        rejected: %i[rejected],
        blocked: %i[blocked]
      }.freeze

      ATTRIBUTES = %i[
        execution_id agent_id execution_revision status phase
        base_agent_revision base_context_revision base_journal_position
        working_records llm_calls approval_request result_ref error_ref
        created_at updated_at terminal_reason metadata
      ].freeze
      attr_reader(*ATTRIBUTES)

      def self.start(agent_root:, input_record:, metadata: {})
        now = Time.now.utc.iso8601(6)
        new(
          execution_id: SecureRandom.uuid,
          agent_id: agent_root.agent_id,
          execution_revision: 0,
          status: :preparing,
          phase: :preparing,
          base_agent_revision: agent_root.agent_revision,
          base_context_revision: agent_root.context_revision,
          base_journal_position: agent_root.journal_position,
          working_records: [input_record],
          llm_calls: [],
          approval_request: nil,
          result_ref: nil,
          error_ref: nil,
          created_at: now,
          updated_at: now,
          terminal_reason: nil,
          metadata: metadata
        )
      end

      def initialize(**attributes)
        ATTRIBUTES.each do |name|
          value = attributes.fetch(name)
          value = value.to_sym if %i[status phase].include?(name)
          instance_variable_set("@#{name}", Immutable.copy(value))
        end
        raise ArgumentError, "unknown execution status: #{status.inspect}" unless TRANSITIONS.key?(status)
        raise ArgumentError, "execution_revision must be non-negative" if execution_revision.negative?
        Immutable.validate_canonical_json!(metadata, label: "Execution metadata")
        if approval_request
          Immutable.validate_canonical_json!(approval_request, label: "Approval request")
        end
        freeze
      end

      def active?
        ACTIVE_STATUSES.include?(status)
      end

      def terminal?
        TERMINAL_STATUSES.include?(status)
      end

      def with(**changes)
        next_status = changes.fetch(:status, status).to_sym
        unless TRANSITIONS.fetch(status).include?(next_status)
          raise ArgumentError, "illegal AgentExecution transition: #{status} -> #{next_status}"
        end
        values = ATTRIBUTES.to_h { |name| [name, public_send(name)] }.merge(changes)
        values[:execution_revision] = execution_revision + 1 unless changes.key?(:execution_revision)
        values[:updated_at] = Time.now.utc.iso8601(6) unless changes.key?(:updated_at)
        self.class.new(**values)
      end

      # Current semantic payload representation. Persistence format identity and
      # compatibility validation are owned by Persistence::DurableCodec.
      # @api public
      def to_h
        ATTRIBUTES.to_h do |name|
          value = public_send(name)
          value = value.map(&:to_h) if name == :working_records
          value = value.map(&:to_h) if name == :llm_calls
          [name.to_s, value]
        end
      end

      # Restores only the current semantic payload shape. Historical durable
      # representations must go through explicit Persistence migration first.
      # @api public
      def self.from_h(hash)
        source = hash.to_h { |key, value| [key.to_s, value] }
        expected = ATTRIBUTES.map(&:to_s).sort
        actual = source.keys.sort
        unless actual == expected
          missing = expected - actual
          unknown = actual - expected
          raise ArgumentError,
            "AgentExecution payload schema mismatch: " \
            "missing=#{missing.inspect}, unknown=#{unknown.inspect}"
        end

        attributes = ATTRIBUTES.to_h do |name|
          [name, source.fetch(name.to_s)]
        end

        attributes[:working_records] = attributes.fetch(:working_records).map do |record|
          record.is_a?(JournalRecord) ? record : JournalRecord.from_h(record)
        end
        attributes[:llm_calls] = attributes.fetch(:llm_calls).map do |call|
          call.is_a?(LLMCallRecord) ? call : LLMCallRecord.from_h(call)
        end

        new(**attributes)
      end
    end
  end
end
