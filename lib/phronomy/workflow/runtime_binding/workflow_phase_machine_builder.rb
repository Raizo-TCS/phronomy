# frozen_string_literal: true

require "state_machines"
require_relative "../execution/workflow_action_rules"

module Phronomy
  # Builds the anonymous state-machine Class used by WorkflowRunner.
  #
  # This class compiles Workflow topology into state_machines declarations.
  # It intentionally does not await Tasks, register completion callbacks,
  # cancel external work, or interpret application event payloads.
  #
  # @api private
  class WorkflowPhaseMachineBuilder
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
      @external_events = external_events.transform_values { |items| items.map { |transition| convert_transition(transition) } }
      @entry_actions = entry_actions
      @auto_transitions = auto_transitions.map { |transition| convert_transition(transition) }
      @exit_actions = exit_actions
    end

    def build
      entry = @entry_point
      all_states = (@declared_states + @wait_state_names + [FSMProtocol::FINISH]).uniq
      auto_transitions = @auto_transitions
      external_events = @external_events
      entry_actions = @entry_actions
      exit_actions = @exit_actions
      condition_builder = method(:build_transition_condition)
      entry_callback_builder = method(:build_entry_callback)
      exit_callback_builder = method(:build_exit_callback)
      transition_callback = build_transition_action_callback

      Class.new do
        attr_accessor(
          :context,
          :current_event,
          :selected_transition_action,
          :selected_transition_metadata
        )

        state_machine :phase, initial: entry do
          all_states.each { |state_name| state state_name }

          event :state_completed do
            auto_transitions.each do |transition_definition|
              transition(
                transition_definition[:from] => transition_definition[:to],
                :if => condition_builder.call(transition_definition)
              )
            end
          end

          external_events.each do |event_name, transitions|
            event event_name do
              transitions.each do |transition_definition|
                transition(
                  transition_definition[:from] => transition_definition[:to],
                  :if => condition_builder.call(transition_definition)
                )
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

          # Both source exit callbacks and the transition action are
          # before_transition callbacks. Register exits first to preserve the
          # required exit -> transition action -> entry ordering.
          exit_actions.each do |state_name, callables|
            callables.each do |callable|
              before_transition(
                from: state_name,
                &exit_callback_builder.call(callable, state_name)
              )
            end
          end

          before_transition(&transition_callback)
        end
      end
    rescue => error
      raise ArgumentError, "Failed to build phase machine: #{error.message}"
    end

    private

    def convert_transition(transition)
      destination = transition[:to]
      destination = FSMProtocol::FINISH if destination == Workflow::Completion::FINISH
      transition.merge(to: destination)
    end

    def build_transition_condition(transition_definition)
      guard = transition_definition[:guard]
      action = transition_definition[:action]
      metadata = {
        from: transition_definition[:from],
        event: transition_definition[:event],
        to: public_destination(transition_definition[:to])
      }.freeze

      ->(machine) {
        matched = WorkflowActionRules.allowed?(guard, machine.context, machine.current_event)
        if matched
          machine.selected_transition_action = action
          machine.selected_transition_metadata = metadata
        end
        matched
      }
    end

    def build_transition_action_callback
      ->(machine) {
        machine.context = WorkflowActionRules.transition(
          machine.selected_transition_action, machine.context, machine.current_event,
          metadata: machine.selected_transition_metadata || {}
        )
      }
    end

    def build_entry_callback(callable, state_name)
      ->(machine) {
        machine.context = WorkflowActionRules.apply_entry(callable, machine.context, state_name)
      }
    end

    def build_exit_callback(callable, state_name)
      ->(machine) { WorkflowActionRules.exit(callable, machine.context, state_name) }
    end

    def public_destination(destination)
      return Workflow::Completion::FINISH if destination == FSMProtocol::FINISH

      destination
    end
  end
end
