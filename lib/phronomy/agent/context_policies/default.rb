# frozen_string_literal: true

module Phronomy
  module Agent
    module ContextPolicies
      class Default < ContextPolicy
        DESCRIPTOR = ContextPolicyDescriptor.new(
          id: "default-recent-v1",
          version: 1,
          config: {}
        )

        def initialize(config = {})
          @config = Immutable.copy(config || {})
        end

        def descriptor
          return DESCRIPTOR if @config.empty?
          ContextPolicyDescriptor.new(id: DESCRIPTOR.id, version: DESCRIPTOR.version, config: @config)
        end

        def call(request)
          units = request.parts.fetch(:unit_builder).build(request.candidates)
          units = request.parts.fetch(:required_context_resolver).resolve(
            request: request,
            units: units
          )
          ordered = request.parts.fetch(:recent_first_selector).order(
            request: request,
            units: units
          )
          selected = request.parts.fetch(:token_budget_packer).pack(
            request: request,
            units: ordered
          )

          ContextPlan.new(
            selected_unit_ids: selected.map(&:unit_id),
            derived_contents: [],
            selected_tool_ids: [],
            ordering_hints: {"history" => "chronological"},
            policy_descriptor: descriptor,
            metadata: {
              "candidate_count" => request.candidates.length,
              "unit_count" => units.length,
              "selected_unit_count" => selected.length
            }
          )
        end
      end
    end
  end
end
