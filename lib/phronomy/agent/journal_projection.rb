# frozen_string_literal: true

module Phronomy
  module Agent
    class JournalProjection
      MESSAGE_KINDS = %i[
        external_message
        assistant_message
        tool_message
      ].freeze
      KNOWLEDGE_RESET_KINDS = %i[knowledge_cleared context_reset].freeze

      def initialize(persistence:, agent_root:)
        @persistence = persistence
        @agent_root = agent_root
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
        (transcript_records + active_knowledge_records)
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
