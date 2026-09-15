# frozen_string_literal: true

module Phronomy
  # Shared terminal-state vocabulary for FSM execution and Workflow compilation.
  # This protocol does not depend on a particular runner or session instance.
  # @api private
  module FSMProtocol
    FINISH = :__end__
  end
end
