# frozen_string_literal: true

module Phronomy
  # Mechanism-neutral completion/failure/retirement decision.
  # @api private
  TerminalDecision = Data.define(:action, :error)
end
