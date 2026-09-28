# frozen_string_literal: true

module Phronomy
  # Shared terminal-state vocabulary and domain decisions for FSM execution.
  # This protocol does not depend on a particular runner or session instance.
  # @api private
  module FSMProtocol
    FINISH = :__end__

    # A domain policy permits completion, reports failure, or retires a session
    # without settling its caller. It never carries live session authority.
    TerminalDecision = Data.define(:action, :error)
  end
end
