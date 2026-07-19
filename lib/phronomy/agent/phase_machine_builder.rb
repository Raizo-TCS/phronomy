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
    #   - after_transition callbacks for each state's entry actions.
    #
    # Guard methods (+input_passed?+, +tool_call_pending?+, etc.) are delegated
    # to the +InvocationContext+ stored in +attr_accessor :context+.
    #
    # @api private
    class PhaseMachineBuilder
      # @param entry_actions   [Hash{Symbol => Array<#call>}]
      # @param action_timeouts [Hash{Symbol => Numeric}]
      # @api private
      def initialize(entry_actions: {}, action_timeouts: {})
        @entry_actions = entry_actions
        @action_timeouts = action_timeouts
      end

      # Builds and returns the PhaseTracker class.
      # @return [Class]
      # @api private
      def build
        entry_acts = @entry_actions
        act_timeouts = @action_timeouts
        build_cb = method(:build_entry_callback)

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

            # ----------------------------------------------------------------
            # Entry action after_transition callbacks
            # Each state's callables are fired after entering that state.
            # ----------------------------------------------------------------
            entry_acts.each do |state_name, callables|
              callables.each do |callable|
                timeout_secs = act_timeouts[state_name]
                cb = build_cb.call(callable, state_name, timeout_secs)
                after_transition to: state_name, do: cb
              end
            end
          end

          # Holds the InvocationContext so guard lambdas can access it.
          attr_accessor :context

          # async_pending flag: set when an entry action returns a Task.
          attr_accessor :async_pending

          # FSM session id — set by FSMSession so async task spawns know the
          # target_id for EventLoop events.
          attr_accessor :session_id

          def initialize
            super
            @context = nil
            @async_pending = false
            @session_id = nil
          end
        end
      end

      private

      # Returns a proc suitable for use as an after_transition callback.
      # @api private
      def build_entry_callback(callable, state_name, timeout_secs)
        handle = method(:handle_entry_action_result)
        ->(machine) {
          result = callable.call(machine.context)
          handle.call(machine, result, state_name, timeout_secs)
        }
      end

      # Dispatches the return value of an entry action.
      # - Task    → async: set async_pending and spawn a background task
      # - context → sync:  update machine.context
      # @api private
      def handle_entry_action_result(machine, result, state_name, timeout_secs)
        if result.is_a?(Phronomy::Task)
          dispatch_task(machine, result, state_name, timeout_secs)
        elsif result.respond_to?(:set_graph_metadata)
          machine.context = result
        end
      end

      # Marks the machine async-pending and spawns a Task to await the result.
      # @api private
      def dispatch_task(machine, result, state_name, timeout_secs)
        machine.async_pending = true
        session_id = machine.session_id
        if timeout_secs
          Phronomy::Runtime.instance.timer_queue.schedule(seconds: timeout_secs) do
            next if result.done?

            Phronomy::EventLoop.instance.post(
              Phronomy::Event.new(
                type: :error,
                target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
                payload: {session_id: session_id, result: Phronomy::ActionTimeoutError.new(
                  "Action in state #{state_name.inspect} timed out after #{timeout_secs}s"
                )}
              )
            )
          end
        end
        result.on_complete do |task_result, error|
          if error
            Phronomy::EventLoop.instance.post(
              Phronomy::Event.new(type: :error, target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID, payload: {session_id: session_id, result: error})
            )
            next
          end
          ev = if task_result.respond_to?(:set_graph_metadata)
            Phronomy::Event.new(type: :action_completed, target_id: session_id, payload: task_result)
          else
            Phronomy::Event.new(type: :state_completed, target_id: session_id, payload: nil)
          end
          Phronomy::EventLoop.instance.post(ev)
        end
      end
    end
  end
end
