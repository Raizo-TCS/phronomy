# frozen_string_literal: true

require_relative "conflict_error"

module Phronomy
  class Persistence
    # A domain ownership, revision or state invariant conflicts with the requested operation.
    # @api public
    class StateConflictError < ConflictError; end
  end
end
