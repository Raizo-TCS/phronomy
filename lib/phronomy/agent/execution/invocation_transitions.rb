# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent phase vocabulary and ordered external transitions. Both the phase
    # machine and FSMSession read this definition; Engine has no Agent policy.
    # Automatic and external transition priority belongs to this Agent contract.
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

      AUTOMATIC_EVENTS = {
        state_completed: [
          {from: :idle, to: :filtering_input, guard: nil},
          {from: :filtering_input, to: :building_context, guard: ->(ctx) { ctx.input_passed? }},
          {from: :filtering_input, to: :blocked, guard: ->(ctx) { ctx.input_blocked? }},
          {from: :building_context, to: :calling_llm, guard: nil},
          {from: :starting_tools, to: :evaluating_tools, guard: nil},
          {from: :evaluating_tools, to: :failed, guard: ->(ctx) { ctx.tool_batch_failed? }},
          {from: :evaluating_tools, to: :blocked, guard: ->(ctx) { ctx.tool_batch_rejected? }},
          {from: :evaluating_tools, to: :recording_tool_results, guard: ->(ctx) { ctx.tool_batch_completed? }},
          {from: :evaluating_tools, to: :suspended, guard: ->(ctx) { ctx.approval_required? }},
          {from: :evaluating_tools, to: :dispatching_tools, guard: ->(ctx) { ctx.ready_to_dispatch? }},
          {from: :evaluating_tools, to: :waiting_for_tools, guard: nil},
          {from: :recording_tool_results, to: :calling_llm, guard: nil},
          {from: :output_filtering, to: :completed, guard: ->(ctx) { ctx.output_passed? }},
          {from: :output_filtering, to: :blocked, guard: ->(ctx) { ctx.output_blocked? }}
        ].each(&:freeze).freeze
      }.freeze

      EVENTS = AUTOMATIC_EVENTS.merge(EXTERNAL_EVENTS).freeze

      def self.next_phase(phase, event, context)
        definition = EVENTS.fetch(event.to_sym, []).find do |candidate|
          candidate[:from] == phase.to_sym &&
            allowed?(candidate, context)
        end
        definition&.fetch(:to)
      end

      def self.allowed?(definition, context)
        guard = definition[:guard]
        !guard || !!(context && guard.call(context))
      end

      def self.recursion_limit(max_iterations)
        12 + ((max_iterations || 10) * 8)
      end
    end
  end
end
