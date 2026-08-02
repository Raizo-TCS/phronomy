# frozen_string_literal: true

require "state_machines"

module Phronomy
  class Workflow
    # Builds the anonymous state-machine Class used by WorkflowRunner.
    #
    # This class compiles Workflow topology into state_machines declarations.
    # It intentionally does not await Tasks, register completion callbacks,
    # cancel external work, or interpret application event payloads.
    #
    # @api private
    class PhaseMachineBuilder
      def initialize(
        entry_point:,
        declared_states:,
        wait_state_names:,
        external_events:,
        entry_actions:,
        auto_transitions:,
        exit_actions:
      )
        @entry_point = entry_point
        @declared_states = declared_states
        @wait_state_names = wait_state_names
        @external_events = external_events
        @entry_actions = entry_actions
        @auto_transitions = auto_transitions
        @exit_actions = exit_actions
      end

      def build
        entry = @entry_point
        all_states = (@declared_states + @wait_state_names + [:__end__]).uniq
        auto_transitions = @auto_transitions
        external_events = @external_events
        entry_actions = @entry_actions
        exit_actions = @exit_actions
        guard_caller = method(:call_guard)
        entry_callback_builder = method(:build_entry_callback)
        exit_callback_builder = method(:build_exit_callback)

        Class.new do
          attr_accessor :context, :current_event

          state_machine :phase, initial: entry do
            all_states.each { |state_name| state state_name }

            event :state_completed do
              auto_transitions.each do |transition_definition|
                if transition_definition[:guard]
                  guard = transition_definition[:guard]
                  transition(
                    transition_definition[:from] => transition_definition[:to],
                    :if => ->(machine) {
                      guard_caller.call(
                        guard,
                        machine.context,
                        machine.current_event
                      )
                    }
                  )
                else
                  transition(
                    transition_definition[:from] => transition_definition[:to]
                  )
                end
              end
            end

            external_events.each do |event_name, transitions|
              event event_name do
                transitions.each do |transition_definition|
                  if transition_definition[:guard]
                    guard = transition_definition[:guard]
                    transition(
                      transition_definition[:from] => transition_definition[:to],
                      :if => ->(machine) {
                        guard_caller.call(
                          guard,
                          machine.context,
                          machine.current_event
                        )
                      }
                    )
                  else
                    transition(
                      transition_definition[:from] => transition_definition[:to]
                    )
                  end
                end
              end
            end

            entry_actions.each do |state_name, callables|
              callables.each do |callable|
                after_transition(
                  to: state_name,
                  &entry_callback_builder.call(callable, state_name)
                )
              end
            end

            exit_actions.each do |state_name, callables|
              callables.each do |callable|
                before_transition(
                  from: state_name,
                  &exit_callback_builder.call(callable, state_name)
                )
              end
            end
          end
        end
      rescue => error
        raise ArgumentError, "Failed to build phase machine: #{error.message}"
      end

      private

      def build_entry_callback(callable, state_name)
        ->(machine) {
          result = callable.call(machine.context)
          if result.is_a?(Phronomy::Task)
            raise Phronomy::InvalidAsyncEntryActionError,
              "Entry action for state #{state_name.inspect} returned Phronomy::Task. " \
              "Start the asynchronous operation, register its callback/listener, " \
              "and return the WorkflowContext or nil."
          end
          machine.context = result if result.is_a?(Phronomy::WorkflowContext)
        }
      end

      def build_exit_callback(callable, state_name)
        ->(machine) {
          result = callable.call(machine.context)
          if result.is_a?(Phronomy::Task)
            raise Phronomy::InvalidAsyncEntryActionError,
              "Exit action for state #{state_name.inspect} returned Phronomy::Task. " \
              "Exit actions are synchronous Run-to-Completion callbacks."
          end
        }
      end

      def call_guard(guard, context, event)
        parameters =
          if guard.respond_to?(:parameters)
            guard.parameters
          else
            guard.method(:call).parameters
          end
        accepts_event = parameters.length >= 2
        accepts_event ? guard.call(context, event) : guard.call(context)
      end
    end
  end
end
