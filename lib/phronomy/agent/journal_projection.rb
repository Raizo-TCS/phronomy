# frozen_string_literal: true

module Phronomy
  module Agent
    class JournalProjection
      MESSAGE_KINDS = %i[external_message llm_message tool_call tool_result].freeze

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

      def llm_call_records
        records.select { |record| record.kind == :llm_call_recorded }
      end

      def records
        @records ||= @persistence.journals.read(@agent_root.agent_id)
      end
    end
  end
end
