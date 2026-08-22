# frozen_string_literal: true

module Phronomy
  module Agent
    module Selection
      class ValidationError < ArgumentError
        attr_reader :code, :unit_ids

        def initialize(message, code:, unit_ids: [])
          @code = code.to_sym
          @unit_ids = Array(unit_ids).map(&:to_s).freeze
          super(message)
        end
      end

      class Validator
        Validated = Data.define(:units, :selected_units, :selected_candidates) do
          def initialize(**values)
            super(**values.merge(
              units: Array(values[:units]).freeze,
              selected_units: Array(values[:selected_units]).freeze,
              selected_candidates: Array(values[:selected_candidates]).freeze
            ))
            freeze
          end
        end

        def validate!(candidates:, units:, selected_unit_ids:)
          all_units = Array(units)
          selected_ids = Array(selected_unit_ids).map(&:to_s)
          unit_index = all_units.to_h { |unit| [unit.unit_id, unit] }

          unknown = selected_ids.reject { |unit_id| unit_index.key?(unit_id) }
          unless unknown.empty?
            raise ValidationError.new(
              "Selection contains unknown units: #{unknown.inspect}",
              code: :unknown_units,
              unit_ids: unknown
            )
          end

          required = all_units.select { |unit| unit.constraint.required? }.map(&:unit_id)
          missing = required - selected_ids
          unless missing.empty?
            raise ValidationError.new(
              "Selection omitted required units: #{missing.inspect}",
              code: :missing_required,
              unit_ids: missing
            )
          end

          forbidden = selected_ids.select { |unit_id| unit_index.fetch(unit_id).constraint.forbidden? }
          unless forbidden.empty?
            raise ValidationError.new(
              "Selection included forbidden units: #{forbidden.inspect}",
              code: :forbidden_selected,
              unit_ids: forbidden
            )
          end

          selected_units = selected_ids.map { |unit_id| unit_index.fetch(unit_id) }
          candidate_index = Array(candidates).to_h { |candidate| [candidate.candidate_id, candidate] }
          selected_candidates = selected_units.flat_map(&:candidate_ids).uniq.map do |candidate_id|
            candidate_index.fetch(candidate_id)
          end
          validate_tool_dependencies!(candidates, selected_candidates)

          Validated.new(
            units: all_units,
            selected_units: selected_units,
            selected_candidates: selected_candidates
          )
        end

        private

        def validate_tool_dependencies!(all_candidates, selected_candidates)
          selected_ids = selected_candidates.to_h { |candidate| [candidate.candidate_id, true] }
          assistants = Array(all_candidates).select { |candidate| candidate.category == :assistant_message }
          tool_messages = Array(all_candidates).select { |candidate| candidate.category == :tool_message }
            .group_by(&:tool_call_id)
          assistant_by_tool_call_id = {}

          tool_messages.each do |tool_call_id, messages|
            if messages.length > 1
              raise ValidationError.new(
                "duplicate Tool message in Selection candidates: #{tool_call_id}",
                code: :invalid_tool_dependency
              )
            end
          end

          assistants.each do |assistant|
            canonical_tool_call_ids(assistant).each do |tool_call_id|
              if assistant_by_tool_call_id.key?(tool_call_id)
                raise ValidationError.new(
                  "duplicate assistant Tool Call id in Selection candidates: #{tool_call_id}",
                  code: :invalid_tool_dependency
                )
              end
              assistant_by_tool_call_id[tool_call_id] = assistant
            end
          end

          assistants.each do |assistant|
            next unless selected_ids[assistant.candidate_id]

            canonical_tool_call_ids(assistant).each do |tool_call_id|
              messages = tool_messages.fetch(tool_call_id, [])
              if messages.empty?
                raise ValidationError.new(
                  "Selection chose assistant Tool Call without a Tool message: #{tool_call_id}",
                  code: :invalid_tool_dependency
                )
              end
              missing = messages.reject { |message| selected_ids[message.candidate_id] }
              unless missing.empty?
                raise ValidationError.new(
                  "Selection split assistant/Tool message dependency: #{tool_call_id}",
                  code: :invalid_tool_dependency
                )
              end
            end
          end

          tool_messages.each do |tool_call_id, messages|
            messages.each do |message|
              next unless selected_ids[message.candidate_id]

              assistant = assistant_by_tool_call_id[tool_call_id]
              unless assistant && selected_ids[assistant.candidate_id]
                raise ValidationError.new(
                  "Selection chose orphan Tool message: #{tool_call_id}",
                  code: :invalid_tool_dependency
                )
              end
            end
          end
        end

        def canonical_tool_call_ids(candidate)
          Array(candidate.metadata["tool_call_ids"] || candidate.metadata[:tool_call_ids])
            .compact
            .map(&:to_s)
        end
      end
    end
  end
end
