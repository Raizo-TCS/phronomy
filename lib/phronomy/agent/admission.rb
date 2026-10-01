# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # The short durable phase of an Agent's already acquired runtime admission.
    # A coordinator may join it to its reservation check; it cannot start an FSM,
    # publish a provisional result or make the Agent interpret a parent's schema.
    # @api public
    class Admission
      attr_reader :agent_id, :execution_id, :correlation

      # Constructed by Agent execution, never restored from a durable record.
      # @api private
      def initialize(persistence:, root:, input:, config:, preparation_metadata:)
        @persistence, @root, @input, @config = persistence, root, input, config
        @preparation_metadata = preparation_metadata
        @agent_id = root.agent_id
        @execution_id = (config[:phronomy_reserved_execution_id] || SecureRandom.uuid).to_s.freeze
        @correlation = Phronomy::Values::Immutable.copy(config[:phronomy_reservation])
        @thread = Thread.current
      end

      # Own a standalone admission transaction.
      # @api public
      def accept
        @persistence.coordinator.atomic { |scope| accept_in(scope) }
        nil
      end

      # Participate without committing or publishing live state.
      # @api public
      def accept_in(scope)
        check_thread!
        raise Phronomy::ConfigurationError, "Agent admission is single-use" if @scope
        @scope = scope
        @persistence.participate(scope) do |records|
          raise Phronomy::Error, "agent is closed: #{agent_id}" if @root.lifecycle_status == :closed
          input_ref = records.contents.put_text(@input)
          context_ref = records.contents.put_json(@config.fetch(:durable_context)) if @config.key?(:durable_context)
          input_record = JournalRecord.new(agent_id: agent_id, kind: :input_received,
            channel: :external, role: :user, content_ref: input_ref,
            context_generation: @root.transcript_generation, context_candidate: false)
          execution = AgentExecution.start(agent_root: @root, input_record: input_record,
            execution_id: execution_id, metadata: {
              "reservation" => correlation, "current_input_ref" => input_ref,
              "durable_context_ref" => context_ref,
              "execution_extension" => @config[:phronomy_execution_participant]&.binding&.to_h
            }.merge(@preparation_metadata).compact)
          input_record = JournalRecord.from_h(input_record.to_h.merge("execution_id" => execution_id))
          execution = execution.with(execution_revision: 0, working_records: [input_record])
          records.executions.create_active(execution)
          next_root = @root.with(agent_revision: @root.agent_revision + 1, lifecycle_status: :active)
          records.agents.save(agent_id, expected_revision: @root.agent_revision, root: next_root)
          @result = [execution, next_root].freeze
        end
        nil
      end

      # Available to Agent execution only after the outermost successful response.
      # @api private
      def result
        check_thread!
        unless @result && @scope&.committed?
          raise Phronomy::Persistence::TransactionError, "Agent admission has not committed"
        end
        @result
      end

      private

      def check_thread!
        raise Phronomy::Persistence::TransactionError, "Agent admission belongs to another execution context" unless @thread.equal?(Thread.current)
      end
    end
  end
end
