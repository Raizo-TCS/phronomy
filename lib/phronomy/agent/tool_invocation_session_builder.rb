# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    # Builds a generic FSMSession for one ToolInvocation.
    # @api private
    class ToolInvocationSessionBuilder
      AUTO_STATE_SET = {
        idle: true,
        validating: true,
        authorizing: true,
        queued: true,
        running: true
      }.freeze

      DECLARED_STATES = %i[
        idle validating authorizing awaiting_approval authorized queued running
        completed failed rejected cancelled
      ].freeze

      WAIT_STATES = %i[awaiting_approval authorized].freeze

      EXTERNAL_EVENTS = {
        approve: [{from: :awaiting_approval, to: :authorized, guard: nil}],
        reject: [{from: :awaiting_approval, to: :rejected, guard: nil}],
        dispatch: [{from: :authorized, to: :queued, guard: nil}],
        cancel: [
          {from: :awaiting_approval, to: :cancelled, guard: nil},
          {from: :authorized, to: :cancelled, guard: nil},
          {from: :queued, to: :cancelled, guard: nil},
          {from: :running, to: :cancelled, guard: nil}
        ]
      }.freeze

      def self.build(tool_invocation:, runtime: Phronomy::Runtime.instance)
        build_session(tool_invocation: tool_invocation, runtime: runtime)
      end

      def self.build_for_resume(
        tool_invocation:,
        resume_event:,
        resume_phase:,
        runtime: Phronomy::Runtime.instance
      )
        build_session(
          tool_invocation: tool_invocation,
          runtime: runtime,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end

      def self.build_session(
        tool_invocation:,
        runtime:,
        resume_event: nil,
        resume_phase: nil
      )
        actions = build_entry_actions(runtime)
        phase_machine = build_phase_machine(actions)

        Phronomy::FSMSession.new(
          id: tool_invocation.id,
          context: tool_invocation,
          entry_point: :idle,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: WAIT_STATES,
          external_events: EXTERNAL_EVENTS,
          recursion_limit: 20,
          event_loop: runtime.event_loop,
          timer_queue_provider: -> { runtime.timer_queue },
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end
      private_class_method :build_session

      def self.build_entry_actions(runtime)
        {
          validating: [method(:validating_action)],
          authorizing: [method(:authorizing_action).curry.call(runtime)],
          awaiting_approval: [method(:awaiting_approval_action).curry.call(runtime)],
          authorized: [method(:authorized_action).curry.call(runtime)],
          queued: [method(:queued_action)],
          running: [method(:running_action).curry.call(runtime)],
          completed: [method(:completed_action).curry.call(runtime)],
          failed: [method(:failed_action).curry.call(runtime)],
          rejected: [method(:rejected_action).curry.call(runtime)],
          cancelled: [method(:cancelled_action).curry.call(runtime)]
        }
      end
      private_class_method :build_entry_actions

      def self.build_phase_machine(entry_actions)
        callbacks = entry_actions
        callback_builder = method(:build_entry_callback)

        Class.new do
          state_machine :phase, initial: :idle do
            state :idle
            state :validating
            state :authorizing
            state :awaiting_approval
            state :authorized
            state :queued
            state :running
            state :completed
            state :failed
            state :rejected
            state :cancelled

            event :state_completed do
              transition idle: :validating

              transition validating: :failed, if: ->(m) { m.context&.failed? }
              transition validating: :completed, if: ->(m) { m.context&.validation_completed? }
              transition validating: :authorizing, if: ->(m) { m.context&.validation_passed? }

              transition authorizing: :cancelled, if: ->(m) { m.context&.cancelled? }
              transition authorizing: :failed, if: ->(m) { m.context&.failed? }
              transition authorizing: :rejected, if: ->(m) { m.context&.rejected? }
              transition authorizing: :awaiting_approval, if: ->(m) { m.context&.awaiting_approval? }
              transition authorizing: :authorized, if: ->(m) { m.context&.authorized? }

              transition queued: :running
              transition running: :cancelled, if: ->(m) { m.context&.cancelled? }
              transition running: :failed, if: ->(m) { m.context&.failed? }
              transition running: :completed, if: ->(m) { m.context&.execution_completed? }
            end

            event :approve do
              transition awaiting_approval: :authorized
            end

            event :reject do
              transition awaiting_approval: :rejected
            end

            event :dispatch do
              transition authorized: :queued
            end

            event :cancel do
              transition awaiting_approval: :cancelled
              transition authorized: :cancelled
              transition queued: :cancelled
              transition running: :cancelled
            end

            callbacks.each do |state_name, callables|
              callables.each do |callable|
                after_transition to: state_name,
                  do: callback_builder.call(callable)
              end
            end
          end

          attr_accessor :context, :async_pending, :session_id, :event_loop, :timer_queue_provider

          def initialize
            super
            @context = nil
            @async_pending = false
            @session_id = nil
          end
        end
      end
      private_class_method :build_phase_machine

      def self.build_entry_callback(callable)
        ->(machine) {
          result = callable.call(machine.context)
          if result.is_a?(Phronomy::Task)
            machine.async_pending = true
            session_id = machine.session_id
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
          elsif result.respond_to?(:set_graph_metadata)
            machine.context = result
          end
        }
      end
      private_class_method :build_entry_callback

      def self.validating_action(invocation)
        invocation.validate!
      end
      private_class_method :validating_action

      def self.authorizing_action(runtime, invocation)
        invocation.authorization_task(runtime: runtime)
      end
      private_class_method :authorizing_action

      def self.awaiting_approval_action(runtime, invocation)
        invocation.mark_awaiting_approval!
        notify_parent(runtime, invocation, :tool_approval_required)
        invocation
      end
      private_class_method :awaiting_approval_action

      def self.authorized_action(runtime, invocation)
        invocation.mark_authorized!
        notify_parent(runtime, invocation, :tool_authorized)
        invocation
      end
      private_class_method :authorized_action

      def self.queued_action(invocation)
        invocation.mark_queued!
      end
      private_class_method :queued_action

      def self.running_action(runtime, invocation)
        task = invocation.execution_task(runtime: runtime)
        invocation.mark_running!
        task
      end
      private_class_method :running_action

      def self.completed_action(runtime, invocation)
        notify_parent(runtime, invocation, :tool_completed)
        invocation
      end
      private_class_method :completed_action

      def self.failed_action(runtime, invocation)
        notify_parent(runtime, invocation, :tool_failed)
        invocation
      end
      private_class_method :failed_action

      def self.rejected_action(runtime, invocation)
        invocation.mark_rejected!
        notify_parent(runtime, invocation, :tool_rejected)
        invocation
      end
      private_class_method :rejected_action

      def self.cancelled_action(runtime, invocation)
        invocation.mark_cancelled!
        notify_parent(runtime, invocation, :tool_cancelled)
        invocation
      end
      private_class_method :cancelled_action

      def self.notify_parent(runtime, invocation, event_type)
        runtime.event_loop.post(
          Phronomy::Event.new(
            type: event_type,
            target_id: invocation.parent_agent_invocation_id,
            payload: {tool_invocation_id: invocation.id}
          )
        )
      end
      private_class_method :notify_parent
    end
  end
end
