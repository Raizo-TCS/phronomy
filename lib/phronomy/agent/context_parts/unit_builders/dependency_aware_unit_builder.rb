# frozen_string_literal: true

require "digest"
require "set"

module Phronomy
  module Agent
    module ContextParts
      module UnitBuilders
        class DependencyAwareUnitBuilder
          def build(candidates)
            ordered = Array(candidates).sort_by { |candidate| [candidate.sequence || 0, candidate.candidate_id] }
            by_id = ordered.to_h { |candidate| [candidate.candidate_id, candidate] }
            tool_results = ordered.select { |candidate| candidate.category == :tool_result }
              .group_by(&:tool_call_id)
            calls_by_llm = ordered.select { |candidate| candidate.category == :tool_call && candidate.llm_call_id }
              .group_by(&:llm_call_id)
            assistant_by_llm = ordered.select do |candidate|
              candidate.llm_call_id && %i[llm_message tool_call].include?(candidate.category)
            end.group_by(&:llm_call_id)

            claimed = Set.new
            units = []
            ordered.each_with_index do |candidate, index|
              next if claimed.include?(candidate.candidate_id)

              group = if runtime_tool_exchange?(candidate, calls_by_llm)
                runtime_tool_exchange(
                  candidate,
                  assistant_by_llm: assistant_by_llm,
                  calls_by_llm: calls_by_llm,
                  tool_results: tool_results
                )
              else
                import_tool_exchange(ordered, index, tool_results)
              end

              if group && !group.empty?
                group.each { |item| claimed << item.candidate_id }
                units << build_unit(group, kind: :tool_exchange)
              else
                claimed << candidate.candidate_id
                units << build_unit([by_id.fetch(candidate.candidate_id)], kind: :message)
              end
            end

            units.sort_by { |unit| unit.sequence_range.first }.freeze
          end

          private

          def runtime_tool_exchange?(candidate, calls_by_llm)
            candidate.llm_call_id &&
              calls_by_llm.key?(candidate.llm_call_id) &&
              %i[llm_message tool_call].include?(candidate.category)
          end

          def runtime_tool_exchange(candidate, assistant_by_llm:, calls_by_llm:, tool_results:)
            llm_call_id = candidate.llm_call_id
            calls = calls_by_llm.fetch(llm_call_id)
            call_ids = calls.map(&:tool_call_id).compact
            assistant = assistant_by_llm.fetch(llm_call_id, [])
            results = call_ids.flat_map { |id| tool_results.fetch(id, []) }
            (assistant + results).uniq.sort_by { |item| [item.sequence || 0, item.candidate_id] }
          end

          def import_tool_exchange(ordered, index, tool_results)
            candidate = ordered.fetch(index)
            return unless %i[llm_message tool_call].include?(candidate.category)
            return if candidate.llm_call_id

            group = []
            cursor = index
            if candidate.category == :llm_message
              next_candidate = ordered[cursor + 1]
              return unless next_candidate &&
                next_candidate.category == :tool_call &&
                contiguous_source?(candidate, next_candidate) &&
                next_candidate.llm_call_id.nil?
              group << candidate
              cursor += 1
            end

            calls = []
            while (item = ordered[cursor]) && item.category == :tool_call && item.llm_call_id.nil?
              if calls.any? && !contiguous_source?(calls.last, item)
                break
              end
              if group.any? && calls.empty? && !contiguous_source?(group.last, item)
                break
              end
              calls << item
              cursor += 1
            end
            return if calls.empty?

            call_ids = calls.map(&:tool_call_id).compact
            results = call_ids.flat_map { |id| tool_results.fetch(id, []) }
            (group + calls + results).uniq.sort_by { |item| [item.sequence || 0, item.candidate_id] }
          end

          def contiguous_source?(left, right)
            left_source = left.metadata["source_sequence"]
            right_source = right.metadata["source_sequence"]
            if left_source && right_source
              Integer(right_source) == Integer(left_source) + 1
            else
              Integer(right.sequence) == Integer(left.sequence) + 1
            end
          end

          def build_unit(candidates, kind:)
            ids = candidates.map(&:candidate_id)
            sequences = candidates.map(&:sequence).compact
            requirements = candidates.map(&:requirement)
            requirement = if requirements.include?(:protocol_required)
              :protocol_required
            elsif requirements.include?(:declared_required)
              :declared_required
            else
              :optional
            end
            tool_call_ids = candidates.map(&:tool_call_id).compact.uniq
            llm_call_ids = candidates.map(&:llm_call_id).compact.uniq
            digest = Digest::SHA256.hexdigest(ids.join("\0"))[0, 20]

            ContextSelectionUnit.new(
              unit_id: "#{kind}:#{digest}",
              candidate_ids: ids,
              dependency_unit_ids: [],
              kind: kind,
              requirement: requirement,
              priority: candidates.map(&:priority).max || 0,
              sequence_range: [sequences.min || 0, sequences.max || 0],
              metadata: {
                "tool_call_ids" => tool_call_ids,
                "llm_call_ids" => llm_call_ids
              }
            )
          end
        end
      end
    end
  end
end
