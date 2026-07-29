# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    # Builds the state_machines-backed PhaseTracker for AgentInvocation.
    # @api private
    class PhaseMachineBuilder
      TOOL_EVENTS = %i[
        tool_authorized
        tool_approval_required
        tool_completed
        tool_failed
        tool_rejected
        tool_cancelled
      ].freeze

      def initialize(entry_actions: {}, action_timeouts: {})
        @entry_actions = entry_actions
        @action_timeouts = action_timeouts
      end

      def build
        entry_acts = @entry_actions
        act_timeouts = @action_timeouts
        build_cb = method(:build_entry_callback)

        Class.new do
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
            state :completed
            state :blocked
            state :failed

            event :state_completed do
              transition idle: :filtering_input

              transition filtering_input: :building_context,
                if: ->(m) { m.context&.input_passed? }
              transition filtering_input: :blocked,
                if: ->(m) { m.context&.input_blocked? }

              transition building_context: :calling_llm

              transition calling_llm: :starting_tools,
                if: ->(m) { m.context&.tool_call_pending? }
              transition calling_llm: :output_filtering

              transition starting_tools: :evaluating_tools

              transition evaluating_tools: :failed,
                if: ->(m) { m.context&.tool_batch_failed? }
              transition evaluating_tools: :blocked,
                if: ->(m) { m.context&.tool_batch_rejected? }
              transition evaluating_tools: :recording_tool_results,
                if: ->(m) { m.context&.tool_batch_completed? }
              transition evaluating_tools: :suspended,
                if: ->(m) { m.context&.approval_required? }
              transition evaluating_tools: :dispatching_tools,
                if: ->(m) { m.context&.ready_to_dispatch? }
              transition evaluating_tools: :waiting_for_tools

              transition dispatching_tools: :evaluating_tools
              transition recording_tool_results: :calling_llm

              transition output_filtering: :completed,
                if: ->(m) { m.context&.output_passed? }
              transition output_filtering: :blocked,
                if: ->(m) { m.context&.output_blocked? }
            end

            TOOL_EVENTS.each do |event_name|
              event event_name do
                transition waiting_for_tools: :evaluating_tools
              end
            end

            event :resume do
              transition suspended: :waiting_for_tools
            end

            entry_acts.each do |state_name, callables|
              callables.each do |callable|
                timeout_secs = act_timeouts[state_name]
                after_transition to: state_name,
                  do: build_cb.call(callable, state_name, timeout_secs)
              end
            end
          end

          attr_accessor :context,
            :async_pending,
            :session_id,
            :event_loop,
            :timer_queue_provider

          def initialize
            super
            @context = nil
            @async_pending = false
            @session_id = nil
          end
        end
      end

      private

      def build_entry_callback(callable, state_name, timeout_secs)
        handle = method(:handle_entry_action_result)
        ->(machine) {
          result = callable.call(machine.context)
          handle.call(machine, result, state_name, timeout_secs)
        }
      end

      def handle_entry_action_result(machine, result, state_name, timeout_secs)
        if result.is_a?(Phronomy::Task)
          dispatch_task(machine, result, state_name, timeout_secs)
        elsif result.respond_to?(:set_graph_metadata)
          machine.context = result
        end
      end

      def dispatch_task(machine, result, state_name, timeout_secs)
        machine.async_pending = true
        session_id = machine.session_id
        if timeout_secs
          machine.timer_queue_provider.call.schedule(seconds: timeout_secs) do
            next if result.done?

            machine.event_loop.post(
              Phronomy::Event.new(
                type: :error,
                target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
                payload: {
                  session_id: session_id,
                  result: Phronomy::ActionTimeoutError.new(
                    "Action in state #{state_name.inspect} timed out after #{timeout_secs}s"
                  )
                }
              )
            )
          end
        end

        result.on_complete do |task_result, error|
          event = if error
            Phronomy::Event.new(
              type: :error,
              target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
              payload: {session_id: session_id, result: error}
            )
          else
            Phronomy::Event.new(
              type: :action_completed,
              target_id: session_id,
              payload: task_result
            )
          end
          machine.event_loop.post(event)
        end
      end
    end
  end
end
