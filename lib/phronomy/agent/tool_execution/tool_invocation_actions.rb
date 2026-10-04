# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent-owned Tool child entry operations and session-local result delivery.
    # Workers return outcomes; the serial owner applies live invocation state.
    # @api private
    class ToolInvocationActions
      def self.build_entry_actions(environment, event_sink, parent_event_sink)
        {
          validating: [method(:validating_action)],
          authorizing: [method(:authorizing_action).curry.call(environment, event_sink)],
          awaiting_approval: [method(:awaiting_approval_action).curry.call(parent_event_sink)],
          authorized: [method(:authorized_action).curry.call(parent_event_sink)],
          queued: [method(:queued_action)],
          running: [method(:running_action).curry.call(environment, event_sink)],
          completed: [method(:completed_action).curry.call(parent_event_sink)],
          failed: [method(:failed_action).curry.call(parent_event_sink)],
          rejected: [method(:rejected_action).curry.call(parent_event_sink)],
          cancelled: [method(:cancelled_action).curry.call(parent_event_sink)]
        }
      end

      def self.validating_action(invocation)
        invocation.validate!
      end
      private_class_method :validating_action

      def self.authorizing_action(environment, event_sink, invocation)
        invocation.start_authorization(environment: environment) do |outcome|
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

      def self.running_action(environment, event_sink, invocation)
        invocation.start_execution(environment: environment) do |outcome|
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
