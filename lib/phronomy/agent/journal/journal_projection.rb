# frozen_string_literal: true

require_relative "../../execution/concurrency/worker_input_restricted"

module Phronomy
  module Agent
    class JournalProjection
      include Phronomy::Concurrency::WorkerInputRestricted

      MESSAGE_KINDS = %i[
        external_message
        assistant_message
        tool_message
      ].freeze
      KNOWLEDGE_RESET_KINDS = %i[knowledge_cleared context_reset].freeze

      def initialize(agent_root:, persistence: nil, records: nil)
        @persistence = persistence
        @agent_root = agent_root
        @records = records&.dup&.freeze
        if @records.nil? && @persistence.nil?
          raise ArgumentError, "JournalProjection requires persistence: or records:"
        end
      end

      def transcript_records
        generation = @agent_root.transcript_generation
        records.select do |record|
          record.context_candidate &&
            record.context_generation == generation &&
            MESSAGE_KINDS.include?(record.kind)
        end
      end

      # Returns all persistent records eligible for Context selection.
      # Knowledge has an independent logical lifetime from the transcript:
      # clear_transcript! does not remove Knowledge, while knowledge_cleared and
      # context_reset invalidate earlier Knowledge records by Journal position.
      def context_records
        rejected_batches = rejected_tool_batches
        messages = transcript_records.reject do |record|
          %i[assistant_message tool_message].include?(record.kind) &&
            record.llm_call_id && rejected_batches[record.execution_id] == record.llm_call_id
        end
        (messages + active_knowledge_records)
          .sort_by { |record| [record.sequence || 0, record.record_id] }
          .freeze
      end

      def llm_call_records
        records.select { |record| record.kind == :llm_call_recorded }
      end

      def records
        @records ||= @persistence.journals.read(@agent_root.agent_id)
      end

      private

      # Rejection ends the execution at its final provider Tool batch. That
      # exchange has no complete set of Tool replies to send to a provider.
      # Identify it from existing journal facts, including pre-upgrade histories.
      def rejected_tool_batches
        rejected = {}
        batches = {}
        records.reverse_each do |record|
          if record.kind == :execution_rejected
            rejected[record.execution_id] = true
          elsif record.kind == :assistant_message && rejected.delete(record.execution_id)
            if Array(record.metadata["tool_call_ids"]).any? && record.llm_call_id
              batches[record.execution_id] = record.llm_call_id
            end
          end
        end
        batches
      end

      def active_knowledge_records
        reset_sequence = records.filter_map do |record|
          record.sequence if KNOWLEDGE_RESET_KINDS.include?(record.kind)
        end.max.to_i

        records.select do |record|
          record.context_candidate &&
            record.kind == :knowledge &&
            record.sequence.to_i > reset_sequence
        end
      end
    end
  end
end
