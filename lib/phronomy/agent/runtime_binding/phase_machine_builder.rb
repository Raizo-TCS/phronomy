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
        declared_states = InvocationTransitions::DECLARED_STATES
        entry_point = InvocationTransitions::ENTRY_POINT

        Class.new do
          attr_accessor :context, :current_event

          state_machine :phase, initial: entry_point do
            declared_states.each { |state_name| state state_name }

            InvocationTransitions::EVENTS.each do |event_name, transitions|
              event event_name do
                transitions.each do |definition|
                  transition definition[:from] => definition[:to],
                    :if => ->(machine) {
                      InvocationTransitions.allowed?(definition, machine.context)
                    }
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
