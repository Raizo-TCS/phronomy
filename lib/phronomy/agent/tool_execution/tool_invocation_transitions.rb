# frozen_string_literal: true

module Phronomy
  module Agent
    # Agent-owned Tool child progress. Ordered guards and source admission
    # share one definition; no FSM library or Runtime is needed to evaluate it.
    # @api private
    module ToolInvocationTransitions
      ENTRY_POINT = :idle
      RECURSION_LIMIT = 20

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
      }.transform_values { |definitions| definitions.each(&:freeze).freeze }.freeze

      AUTOMATIC_EVENTS = {
        state_completed: [
          {from: :idle, to: :validating, guard: nil},
          {from: :validating, to: :failed, guard: ->(ctx) { ctx.failed? }},
          {from: :validating, to: :completed, guard: ->(ctx) { ctx.validation_completed? }},
          {from: :validating, to: :authorizing, guard: ->(ctx) { ctx.validation_passed? }},
          {from: :queued, to: :running, guard: nil}
        ].each(&:freeze).freeze
      }.freeze

      EVENTS = AUTOMATIC_EVENTS.merge(EXTERNAL_EVENTS).freeze

      def self.next_phase(phase, event, context)
        definition = EVENTS.fetch(event.to_sym, []).find do |candidate|
          candidate[:from] == phase.to_sym && allowed?(candidate, context)
        end
        definition&.fetch(:to)
      end

      def self.allowed?(definition, context)
        guard = definition[:guard]
        !guard || !!(context && guard.call(context))
      end
    end
  end
end
