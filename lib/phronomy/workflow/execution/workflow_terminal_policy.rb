# frozen_string_literal: true

module Phronomy
  # Interprets durable Workflow results for the shared FSM terminal gate.
  # The session owns pending state; Runner owns persistence and reconciliation.
  # @api private
  class WorkflowTerminalPolicy
    include Phronomy::Concurrency::WorkerInputRestricted

    def initialize(persist:)
      @persist = persist
    end

    def start(terminal_type:, context:, event_sink:)
      @persist.call(terminal_type: terminal_type, context: context, event_sink: event_sink)
    end

    def handles?(event)
      event.type == :workflow_terminal_persistence_result
    end

    def decision_for(event)
      result = event.payload
      case result.outcome
      when :success
        FSMProtocol::TerminalDecision.new(action: :complete, error: nil)
      when :known_failure
        FSMProtocol::TerminalDecision.new(
          action: :fail,
          error: result.error || Phronomy::Error.new("Workflow terminal persistence failed")
        )
      when :outcome_unknown
        FSMProtocol::TerminalDecision.new(action: :retire, error: result.error)
      else
        raise Phronomy::Error,
          "unknown Workflow terminal persistence outcome: #{result.outcome.inspect}"
      end
    end
  end
end
