# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    # Builds the state_machines-backed PhaseTracker class for Agent invocations.
    #
    # This is the Agent counterpart to Workflow::PhaseMachineBuilder.
    # Unlike the Workflow version (which builds a dynamic graph from user-defined
    # DSL), this always generates the same fixed graph representing the
    # Agent invoke execution phases.
    #
    # The generated class holds a single +:phase+ state machine with:
    #   - One automatic event (+:state_completed+) that FSMSession fires after
    #     each entry action completes.
    #   - Two external events (+:approve+, +:reject+) for HITL.
    #
    # Guard methods (+input_passed?+, +tool_call_pending?+, etc.) are delegated
    # to the +InvocationContext+ stored in +attr_accessor :context+.
    #
    # == State transition table
    #
    # See docs/refactoring_agent_fsm_20260617.md for the full specification.
    #
    # @api private
    class PhaseMachineBuilder
      # Builds and returns the PhaseTracker class.
      # @return [Class]
      # @api private
      def build
        Class.new do
          # state_machines requires a class-level state machine definition.
          state_machine :phase, initial: :idle do
            # ----------------------------------------------------------------
            # State declarations
            # ----------------------------------------------------------------
            state :idle
            state :filtering_input
            state :building_context
            state :calling_llm
            state :executing_tool
            state :awaiting_approval  # wait_state: external event required
            state :output_filtering
            state :completed          # terminal
            state :blocked            # terminal

            # ----------------------------------------------------------------
            # Automatic transitions (fired by FSMSession on state_completed)
            # Guards are evaluated on the InvocationContext via #context.
            # ----------------------------------------------------------------
            event :state_completed do
              # idle → filtering_input (unconditional)
              transition idle: :filtering_input

              # filtering_input → building_context | blocked
              transition filtering_input: :building_context, if: ->(m) { m.context&.input_passed? }
              transition filtering_input: :blocked, if: ->(m) { m.context&.input_blocked? }

              # building_context → calling_llm (unconditional)
              transition building_context: :calling_llm

              # calling_llm → executing_tool | output_filtering
              transition calling_llm: :executing_tool, if: ->(m) { m.context&.tool_call_pending? }
              transition calling_llm: :output_filtering

              # executing_tool → awaiting_approval | calling_llm
              transition executing_tool: :awaiting_approval, if: ->(m) { m.context&.approval_required? }
              transition executing_tool: :calling_llm

              # output_filtering → completed | blocked
              transition output_filtering: :completed, if: ->(m) { m.context&.output_passed? }
              transition output_filtering: :blocked, if: ->(m) { m.context&.output_blocked? }
            end

            # ----------------------------------------------------------------
            # External events (human-in-the-loop)
            # ----------------------------------------------------------------
            event :approve do
              transition awaiting_approval: :executing_tool
            end

            event :reject do
              transition awaiting_approval: :blocked
            end
          end

          # Holds the InvocationContext so guard lambdas can access it.
          attr_accessor :context

          # async_pending flag: set by FSMSession when an entry action returns
          # a Task. Mirrors the same flag used by Workflow::PhaseMachineBuilder.
          attr_accessor :async_pending

          def initialize
            super
            @context = nil
            @async_pending = false
          end
        end
      end
    end
  end
end
