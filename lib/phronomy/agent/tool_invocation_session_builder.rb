# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    # Builds an FSMSession for one ToolInvocation.
    # Async completion is represented only by explicit FSM events.
    class ToolInvocationSessionBuilder
      AUTO_STATE_SET = {idle: true, validating: true, queued: true}.freeze

      DECLARED_STATES = %i[
        idle validating authorizing awaiting_approval authorized queued running
        completed failed rejected cancelled
      ].freeze

      WAIT_STATES = %i[awaiting_approval authorized].freeze

      EXTERNAL_EVENTS = {
        authorization_completed: [
          {from: :authorizing, to: :cancelled, guard: ->(ctx) { ctx.cancelled? }},
          {from: :authorizing, to: :failed, guard: ->(ctx) { ctx.failed? }},
          {from: :authorizing, to: :rejected, guard: ->(ctx) { ctx.rejected? }},
          {from: :authorizing, to: :awaiting_approval, guard: ->(ctx) { ctx.awaiting_approval? }},
          {from: :authorizing, to: :authorized, guard: ->(ctx) { ctx.authorized? }}
        ],
        execution_completed: [
          {from: :running, to: :cancelled, guard: ->(ctx) { ctx.cancelled? }},
          {from: :running, to: :failed, guard: ->(ctx) { ctx.failed? }},
          {from: :running, to: :completed, guard: ->(ctx) { ctx.execution_completed? }}
        ],
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

      def self.build(
        tool_invocation:,
        parent_event_sink:,
        runtime: Phronomy::Runtime.instance
      )
        build_session(
          tool_invocation: tool_invocation,
          parent_event_sink: parent_event_sink,
          runtime: runtime
        )
      end

      def self.build_for_resume(
        tool_invocation:,
        parent_event_sink:,
        resume_event:,
        resume_phase:,
        runtime: Phronomy::Runtime.instance
      )
        build_session(
          tool_invocation: tool_invocation,
          parent_event_sink: parent_event_sink,
          runtime: runtime,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end

      def self.build_session(
        tool_invocation:,
        parent_event_sink:,
        runtime:,
        resume_event: nil,
        resume_phase: nil
      )
        event_sink = Phronomy::FSMSession::EventSink.new(event_loop: runtime.event_loop)
        actions = build_entry_actions(runtime, event_sink, parent_event_sink)
        phase_machine = build_phase_machine(actions)

        Phronomy::FSMSession.new(
          context: tool_invocation,
          event_sink: event_sink,
          entry_point: :idle,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: WAIT_STATES,
          external_events: EXTERNAL_EVENTS,
          recursion_limit: 20,
          event_loop: runtime.event_loop,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end
      private_class_method :build_session

      def self.build_entry_actions(runtime, event_sink, parent_event_sink)
        {
          validating: [method(:validating_action)],
          authorizing: [method(:authorizing_action).curry.call(runtime, event_sink)],
          awaiting_approval: [method(:awaiting_approval_action).curry.call(parent_event_sink)],
          authorized: [method(:authorized_action).curry.call(parent_event_sink)],
          queued: [method(:queued_action)],
          running: [method(:running_action).curry.call(runtime, event_sink)],
          completed: [method(:completed_action).curry.call(parent_event_sink)],
          failed: [method(:failed_action).curry.call(parent_event_sink)],
          rejected: [method(:rejected_action).curry.call(parent_event_sink)],
          cancelled: [method(:cancelled_action).curry.call(parent_event_sink)]
        }
      end
      private_class_method :build_entry_actions

      def self.build_phase_machine(entry_actions)
        callbacks = entry_actions
        callback_builder = method(:build_entry_callback)

        Class.new do
          attr_accessor :context, :current_event

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
              transition queued: :running
            end

            event :authorization_completed do
              transition authorizing: :cancelled, if: ->(m) { m.context&.cancelled? }
              transition authorizing: :failed, if: ->(m) { m.context&.failed? }
              transition authorizing: :rejected, if: ->(m) { m.context&.rejected? }
              transition authorizing: :awaiting_approval, if: ->(m) { m.context&.awaiting_approval? }
              transition authorizing: :authorized, if: ->(m) { m.context&.authorized? }
            end

            event :execution_completed do
              transition running: :cancelled, if: ->(m) { m.context&.cancelled? }
              transition running: :failed, if: ->(m) { m.context&.failed? }
              transition running: :completed, if: ->(m) { m.context&.execution_completed? }
            end

            event(:approve) { transition awaiting_approval: :authorized }
            event(:reject) { transition awaiting_approval: :rejected }
            event(:dispatch) { transition authorized: :queued }
            event :cancel do
              transition awaiting_approval: :cancelled
              transition authorized: :cancelled
              transition queued: :cancelled
              transition running: :cancelled
            end

            callbacks.each do |state_name, callables|
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
      private_class_method :build_phase_machine

      def self.build_entry_callback(callable, state_name)
        ->(machine) {
          result = callable.call(machine.context)
          if result.is_a?(Phronomy::Task)
            raise Phronomy::InvalidAsyncEntryActionError,
              "Tool entry action for #{state_name.inspect} returned Phronomy::Task"
          end
          machine.context = result if result.respond_to?(:set_graph_metadata)
        }
      end
      private_class_method :build_entry_callback

      def self.validating_action(invocation)
        invocation.validate!
      end
      private_class_method :validating_action

      def self.authorizing_action(runtime, event_sink, invocation)
        invocation.start_authorization(runtime: runtime) do |outcome|
          post_to_session(event_sink, :authorization_completed, outcome)
        end
        invocation
      end
      private_class_method :authorizing_action

      def self.awaiting_approval_action(parent_event_sink, invocation)
        invocation.mark_awaiting_approval!
        notify_parent(parent_event_sink, invocation, :tool_approval_required)
        invocation
      end
      private_class_method :awaiting_approval_action

      def self.authorized_action(parent_event_sink, invocation)
        invocation.mark_authorized!
        notify_parent(parent_event_sink, invocation, :tool_authorized)
        invocation
      end
      private_class_method :authorized_action

      def self.queued_action(invocation)
        invocation.mark_queued!
      end
      private_class_method :queued_action

      def self.running_action(runtime, event_sink, invocation)
        invocation.start_execution(runtime: runtime) do |outcome|
          post_to_session(event_sink, :execution_completed, outcome)
        end
        invocation.mark_running!
        invocation
      end
      private_class_method :running_action

      def self.completed_action(parent_event_sink, invocation)
        notify_parent(parent_event_sink, invocation, :tool_completed)
        invocation
      end
      private_class_method :completed_action

      def self.failed_action(parent_event_sink, invocation)
        notify_parent(parent_event_sink, invocation, :tool_failed)
        invocation
      end
      private_class_method :failed_action

      def self.rejected_action(parent_event_sink, invocation)
        invocation.mark_rejected!
        notify_parent(parent_event_sink, invocation, :tool_rejected)
        invocation
      end
      private_class_method :rejected_action

      def self.cancelled_action(parent_event_sink, invocation)
        invocation.mark_cancelled!
        notify_parent(parent_event_sink, invocation, :tool_cancelled)
        invocation
      end
      private_class_method :cancelled_action

      def self.post_to_session(event_sink, event_type, payload)
        return if event_sink.post(event_type, payload)

        Phronomy.configuration.logger&.warn(
          "[Phronomy] Dropped #{event_type.inspect} for " \
          "FSMSession #{event_sink.fsm_session_id}"
        )
      end
      private_class_method :post_to_session

      def self.notify_parent(parent_event_sink, invocation, event_type)
        parent_event_sink.post(event_type, {tool_invocation_id: invocation.id})
      end
      private_class_method :notify_parent
    end
  end
end
