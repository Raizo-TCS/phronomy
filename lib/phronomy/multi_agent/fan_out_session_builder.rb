# frozen_string_literal: true

require "state_machines"

module Phronomy
  module MultiAgent
    # Builds and registers a fan-out coordination FSMSession.
    class FanOutSessionBuilder
      AUTO_STATE_SET = {idle: true}.freeze
      DECLARED_STATES = %i[idle running completed failed timed_out cancelled].freeze
      WAIT_STATES = [].freeze

      def self.start(
        invocation:,
        timeout: nil,
        cancellation_token: nil,
        runtime: Phronomy::Runtime.instance
      )
        result = Phronomy::Task.deferred(name: "fan-out")

        if cancellation_token&.cancelled?
          result.fail(Phronomy::CancellationError.new("fan-out cancelled"))
          return result
        end

        session = build(invocation: invocation, runtime: runtime)
        source = Phronomy::Task.deferred(name: "fan-out-source:#{session.id}")
        source.on_complete do |context, error|
          if error
            result.fail(error)
          elsif context.error
            result.fail(context.error)
          else
            result.complete(context.results)
          end
        end

        runtime.event_loop.register(session, completion: source)
        if timeout
          runtime.timer_queue.schedule(seconds: timeout) do
            session.event_sink.post(
              :timeout,
              {message: "dispatch_parallel timed out after #{timeout}s"}
            )
          end
        end
        cancellation_token&.on_cancel do
          session.event_sink.post(:cancel, nil)
        end
        result
      rescue => error
        result ||= Phronomy::Task.deferred(name: "fan-out:registration")
        result.fail(error)
        result
      end

      def self.build(invocation:, runtime:)
        event_sink = Phronomy::FSMSession::EventSink.new(event_loop: runtime.event_loop)
        phase_machine = build_phase_machine(runtime, event_sink)
        external_events = {
          child_completed: [{from: :running, to: :running, guard: nil}],
          driver_failed: [{from: :running, to: :failed, guard: nil}],
          timeout: [{from: :running, to: :timed_out, guard: nil}],
          cancel: [{from: :running, to: :cancelled, guard: nil}]
        }

        Phronomy::FSMSession.new(
          context: invocation,
          event_sink: event_sink,
          entry_point: :idle,
          entry_actions: {},
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: WAIT_STATES,
          external_events: external_events,
          phase_machine_class: phase_machine,
          recursion_limit: 10_000,
          event_loop: runtime.event_loop
        )
      end
      private_class_method :build

      def self.build_phase_machine(runtime, event_sink)
        Class.new do
          attr_accessor :context, :current_event

          state_machine :phase, initial: :idle do
            state :idle
            state :running
            state :completed
            state :failed
            state :timed_out
            state :cancelled

            event :state_completed do
              transition idle: :running
            end

            event :child_completed do
              transition running: :failed, if: ->(m) { m.context&.failed? }
              transition running: :completed, if: ->(m) { m.context&.completed? }
              transition running: :running
            end

            event(:driver_failed) { transition running: :failed }
            event(:timeout) { transition running: :timed_out }
            event(:cancel) { transition running: :cancelled }

            after_transition to: :running do |machine|
              machine.context.start_available!(runtime, event_sink: event_sink)
            end
          end
        end
      end
      private_class_method :build_phase_machine
    end
  end
end
