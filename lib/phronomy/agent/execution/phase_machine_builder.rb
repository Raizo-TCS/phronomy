# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    class PhaseMachineBuilder
      def initialize(entry_actions: {})
        @entry_actions = entry_actions
      end

      def build
        entry_actions = @entry_actions
        callback_builder = method(:build_entry_callback)
        condition_builder = method(:build_transition_condition)
        external_events = InvocationTransitions::EXTERNAL_EVENTS
        declared_states = InvocationTransitions::DECLARED_STATES
        entry_point = InvocationTransitions::ENTRY_POINT

        Class.new do
          attr_accessor :context, :current_event

          state_machine :phase, initial: entry_point do
            declared_states.each { |state_name| state state_name }

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

              transition recording_tool_results: :calling_llm

              transition output_filtering: :completed,
                if: ->(machine) { machine.context&.output_passed? }
              transition output_filtering: :blocked,
                if: ->(machine) { machine.context&.output_blocked? }
            end

            external_events.each do |event_name, transitions|
              event event_name do
                transitions.each do |definition|
                  transition(
                    definition[:from] => definition[:to],
                    :if => condition_builder.call(definition)
                  )
                end
              end
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

      def build_transition_condition(definition)
        guard = definition[:guard]
        ->(machine) {
          guard.nil? || (!machine.context.nil? && guard.call(machine.context))
        }
      end

      def build_entry_callback(callable, state_name)
        ->(machine) {
          result = callable.call(machine.context)
          if result.is_a?(Phronomy::TaskResult)
            raise Phronomy::InvalidAsyncEntryActionError,
              "Agent entry action for #{state_name.inspect} returned Phronomy::TaskResult"
          end
          machine.context = result if result.respond_to?(:set_graph_metadata)
        }
      end
    end
  end
end
