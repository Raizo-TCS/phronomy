# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    class PhaseMachineBuilder
      TOOL_EVENTS = %i[
        tool_authorized
        tool_approval_required
        tool_completed
        tool_failed
        tool_rejected
        tool_cancelled
      ].freeze

      def initialize(entry_actions: {})
        @entry_actions = entry_actions
      end

      def build
        entry_actions = @entry_actions
        callback_builder = method(:build_entry_callback)

        Class.new do
          attr_accessor :context, :current_event

          state_machine :phase, initial: :idle do
            state :idle
            state :filtering_input
            state :building_context
            state :calling_llm
            state :starting_tools
            state :evaluating_tools
            state :waiting_for_tools
            state :dispatching_tools
            state :recording_tool_results
            state :suspended
            state :output_filtering
            state :handed_off
            state :completed
            state :blocked
            state :failed

            event :state_completed do
              transition idle: :filtering_input

              transition filtering_input: :building_context,
                if: ->(machine) { machine.context&.input_passed? }
              transition filtering_input: :blocked,
                if: ->(machine) { machine.context&.input_blocked? }

              transition building_context: :calling_llm
              transition starting_tools: :evaluating_tools

              transition evaluating_tools: :failed,
                if: ->(machine) { machine.context&.tool_batch_failed? }
              transition evaluating_tools: :blocked,
                if: ->(machine) { machine.context&.tool_batch_rejected? }
              transition evaluating_tools: :recording_tool_results,
                if: ->(machine) { machine.context&.tool_batch_completed? }
              transition evaluating_tools: :suspended,
                if: ->(machine) { machine.context&.approval_required? }
              transition evaluating_tools: :dispatching_tools,
                if: ->(machine) { machine.context&.ready_to_dispatch? }
              transition evaluating_tools: :waiting_for_tools

              transition dispatching_tools: :evaluating_tools
              transition recording_tool_results: :calling_llm

              transition output_filtering: :completed,
                if: ->(machine) { machine.context&.output_passed? }
              transition output_filtering: :blocked,
                if: ->(machine) { machine.context&.output_blocked? }
            end

            event :llm_completed do
              transition calling_llm: :failed,
                if: ->(machine) { machine.context&.handoff_failed? }
              transition calling_llm: :handed_off,
                if: ->(machine) { machine.context&.handoff_requested? }
              transition calling_llm: :starting_tools,
                if: ->(machine) { machine.context&.tool_call_pending? }
              transition calling_llm: :output_filtering
            end

            event :llm_failed do
              transition calling_llm: :failed
            end

            TOOL_EVENTS.each do |event_name|
              event event_name do
                transition waiting_for_tools: :evaluating_tools
              end
            end

            event :resume do
              transition suspended: :waiting_for_tools
            end

            event :application_callback_failed do
              transition filtering_input: :failed
              transition building_context: :failed
              transition calling_llm: :failed
              transition starting_tools: :failed
              transition evaluating_tools: :failed
              transition waiting_for_tools: :failed
              transition dispatching_tools: :failed
              transition recording_tool_results: :failed
              transition output_filtering: :failed
            end

            entry_actions.each do |state_name, callables|
              callables.each do |callable|
                after_transition(
                  to: state_name,
                  do: callback_builder.call(callable, state_name)
                )
              end
            end
          end
        end
      end

      private

      def build_entry_callback(callable, state_name)
        ->(machine) {
          result = callable.call(machine.context)
          if result.is_a?(Phronomy::Task)
            raise Phronomy::InvalidAsyncEntryActionError,
              "Agent entry action for #{state_name.inspect} returned Phronomy::Task"
          end
          machine.context = result if result.respond_to?(:set_graph_metadata)
        }
      end
    end
  end
end
