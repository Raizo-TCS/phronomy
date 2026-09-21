# frozen_string_literal: true

module Phronomy
  module Storage
    # A stored nonterminal execution prevents another admission or an idle-only
    # operation for the same owner. Other identity/revision conflicts use
    # ConflictError without this subtype. Domain repositories choose the
    # caller-facing lifecycle exception.
    # @api public
    class ActiveExecutionConflictError < ConflictError; end
  end
end
