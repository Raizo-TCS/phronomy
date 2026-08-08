# frozen_string_literal: true

module Phronomy
  module Agent
    class ContextCandidateResolver
      def initialize(content_loader:)
        @content_loader = content_loader
      end

      def resolve(prior_records:, working_records:, excluded_record_ids: [])
        excluded = Array(excluded_record_ids).compact.map(&:to_s).to_h { |id| [id, true] }
        prior = eligible(prior_records, excluded)
        working = eligible(working_records, excluded)
        next_sequence = prior.map(&:sequence).compact.max.to_i

        candidates = []
        prior.each do |record|
          candidates << candidate_for(record, source_kind: :journal, sequence: record.sequence)
        end
        working.each do |record|
          sequence = record.sequence || (next_sequence += 1)
          candidates << candidate_for(record, source_kind: :working, sequence: sequence)
        end
        candidates.sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }.freeze
      end

      private

      def eligible(records, excluded)
        Array(records).select do |record|
          record.context_candidate &&
            record.content_ref &&
            !excluded.key?(record.record_id.to_s)
        end
      end

      def candidate_for(record, source_kind:, sequence:)
        tool_call_id = record.metadata["tool_call_id"] || record.metadata[:tool_call_id]
        bytes = @content_loader.call(record.content_ref)
        metadata = record.metadata.merge(
          "estimated_tokens" => Phronomy::LlmContextWindow::TokenEstimator.estimate(bytes),
          "source_kind" => source_kind.to_s,
          "source_sequence" => record.sequence
        )

        ContextCandidate.new(
          candidate_id: "record:#{record.record_id}",
          source_kind: source_kind,
          category: record.kind,
          role: record.role,
          content_ref: record.content_ref,
          record_id: record.record_id,
          agent_id: record.agent_id,
          execution_id: record.execution_id,
          llm_call_id: record.llm_call_id,
          tool_call_id: tool_call_id,
          sequence: sequence,
          requirement: :optional,
          priority: source_kind == :working ? 100 : 0,
          metadata: metadata
        )
      end
    end
  end
end
