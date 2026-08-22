# frozen_string_literal: true

require "digest"
require "set"

module Phronomy
  module Agent
    module Selection
      module UnitBuilders
        class DependencyAwareUnitBuilder
          def build(candidates)
            ordered = Array(candidates).sort_by do |candidate|
              [candidate.sequence || 0, candidate.candidate_id]
            end

            canonical_assistants = ordered.select do |candidate|
              candidate.category == :assistant_message
            end
            canonical_tool_messages = ordered.select do |candidate|
              candidate.category == :tool_message
            end.group_by(&:tool_call_id)
            assistant_by_tool_call_id = canonical_assistants.each_with_object({}) do |candidate, result|
              canonical_tool_call_ids(candidate).each do |tool_call_id|
                if result.key?(tool_call_id)
                  raise ArgumentError,
                    "duplicate assistant Tool Call id in Selection candidates: #{tool_call_id}"
                end
                result[tool_call_id] = candidate
              end
            end

            claimed = Set.new
            units = []
            ordered.each do |candidate|
              next if claimed.include?(candidate.candidate_id)

              group = canonical_tool_exchange(
                candidate,
                assistant_by_tool_call_id: assistant_by_tool_call_id,
                tool_messages: canonical_tool_messages
              )

              if group && !group.empty?
                group.each { |item| claimed << item.candidate_id }
                units << build_unit(group, kind: :tool_exchange)
              else
                claimed << candidate.candidate_id
                units << build_unit([candidate], kind: :message)
              end
            end

            units.sort_by { |unit| unit.sequence_range.first }.freeze
          end

          private

          def canonical_tool_exchange(candidate, assistant_by_tool_call_id:, tool_messages:)
            assistant = if candidate.category == :assistant_message
              candidate
            elsif candidate.category == :tool_message
              assistant_by_tool_call_id[candidate.tool_call_id]
            end
            return unless assistant

            call_ids = canonical_tool_call_ids(assistant)
            return if call_ids.empty?

            messages = call_ids.flat_map do |tool_call_id|
              tool_messages.fetch(tool_call_id, [])
            end
            ([assistant] + messages).uniq.sort_by do |item|
              [item.sequence || 0, item.candidate_id]
            end
          end

          def canonical_tool_call_ids(candidate)
            Array(candidate.metadata["tool_call_ids"] || candidate.metadata[:tool_call_ids])
              .compact
              .map(&:to_s)
          end

          def build_unit(candidates, kind:)
            ids = candidates.map(&:candidate_id)
            sequences = candidates.map(&:sequence).compact
            constraint = combined_constraint(candidates)
            tool_call_ids = candidates.flat_map do |candidate|
              call_ids = canonical_tool_call_ids(candidate)
              call_ids << candidate.tool_call_id if candidate.tool_call_id
              call_ids
            end.compact.uniq
            llm_call_ids = candidates.map(&:llm_call_id).compact.uniq
            digest = Digest::SHA256.hexdigest(ids.join("\0"))[0, 20]

            Unit.new(
              unit_id: "#{kind}:#{digest}",
              candidate_ids: ids,
              dependency_unit_ids: [],
              kind: kind,
              constraint: constraint,
              priority: candidates.map(&:priority).max || 0,
              sequence_range: [sequences.min || 0, sequences.max || 0],
              metadata: {
                "tool_call_ids" => tool_call_ids,
                "llm_call_ids" => llm_call_ids
              }
            )
          end

          def combined_constraint(candidates)
            constraints = candidates.map(&:constraint)
            if constraints.any?(&:forbidden?) && constraints.any?(&:required?)
              raise ArgumentError,
                "Selection unit contains conflicting required and forbidden candidates"
            end
            return constraints.find(&:forbidden?) if constraints.any?(&:forbidden?)
            return constraints.find(&:required?) if constraints.any?(&:required?)

            constraints.first || Constraint.selectable(origin: :context_policy)
          end
        end
      end
    end
  end
end
