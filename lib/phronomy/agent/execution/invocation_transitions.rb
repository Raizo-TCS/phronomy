# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent phase vocabulary and ordered external transitions. Both the phase
    # machine and FSMSession read this definition; Engine has no Agent policy.
    # Automatic transition behavior and entry actions retain their own owners.
    # @api private
    module InvocationTransitions
      ENTRY_POINT = :idle

      AUTO_STATE_SET = {
        idle: true,
        filtering_input: true,
        building_context: true,
        starting_tools: true,
        evaluating_tools: true,
        recording_tool_results: true,
        output_filtering: true
      }.freeze

      DECLARED_STATES = %i[
        idle filtering_input building_context calling_llm starting_tools
        evaluating_tools waiting_for_tools dispatching_tools
        recording_tool_results suspended output_filtering handed_off completed blocked failed
      ].freeze

      WAIT_STATES = %i[suspended].freeze

      TOOL_EVENTS = %i[
        tool_authorized
        tool_approval_required
        tool_completed
        tool_failed
        tool_rejected
        tool_cancelled
      ].freeze

      EXTERNAL_EVENTS = begin
        tool_transitions = TOOL_EVENTS.to_h do |event_name|
          [event_name, [{from: :waiting_for_tools, to: :evaluating_tools, guard: nil}]]
        end

        events = tool_transitions.merge(
          llm_completed: [
            {from: :calling_llm, to: :failed, guard: ->(ctx) { ctx.callback_failed? }},
            {from: :calling_llm, to: :failed, guard: ->(ctx) { ctx.handoff_failed? }},
            {from: :calling_llm, to: :handed_off, guard: ->(ctx) { ctx.handoff_requested? }},
            {from: :calling_llm, to: :starting_tools, guard: ->(ctx) { ctx.tool_call_pending? }},
            {from: :calling_llm, to: :output_filtering, guard: nil}
          ],
          llm_failed: [
            {from: :calling_llm, to: :failed, guard: nil}
          ],
          llm_setup_failed: [
            {from: :calling_llm, to: :failed, guard: nil}
          ],
          tool_setup_failed: [
            {from: :dispatching_tools, to: :failed, guard: nil}
          ],
          tool_dispatch_prepared: [
            {from: :dispatching_tools, to: :evaluating_tools, guard: nil}
          ],
          resume: [
            {from: :suspended, to: :waiting_for_tools, guard: nil}
          ],
          application_callback_failed: [
            {from: :filtering_input, to: :failed, guard: nil},
            {from: :building_context, to: :failed, guard: nil},
            {from: :calling_llm, to: :failed, guard: nil},
            {from: :starting_tools, to: :failed, guard: nil},
            {from: :evaluating_tools, to: :failed, guard: nil},
            {from: :waiting_for_tools, to: :failed, guard: nil},
            {from: :dispatching_tools, to: :failed, guard: nil},
            {from: :recording_tool_results, to: :failed, guard: nil},
            {from: :output_filtering, to: :failed, guard: nil}
          ]
        )
        events.each_value do |transitions|
          transitions.each(&:freeze).freeze
        end
        events.freeze
      end
    end
  end
end
