# frozen_string_literal: true

require_relative "error"

module Phronomy
  class Persistence
    # A known persistence conflict, including backend compare-and-swap failure.
    # @api public
    class ConflictError < Error; end
  end
end
