# frozen_string_literal: true

require_relative "error"

module Phronomy
  class Persistence
    # A persisted domain value cannot be encoded, decoded or validated.
    # @api public
    class SerializationError < Error; end
  end
end
