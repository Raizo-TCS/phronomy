# frozen_string_literal: true

require_relative "error"

module Phronomy
  class Persistence
    # A required persisted domain object does not exist.
    # @api public
    class NotFoundError < Error; end
  end
end
