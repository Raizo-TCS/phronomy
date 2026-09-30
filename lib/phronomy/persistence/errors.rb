# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  class Persistence
    # Failures describe a category, not a universal claim about commit outcome.
    class Error < Phronomy::Error; end
    class ConflictError < Error; end
    class StateConflictError < ConflictError; end
    class NotFoundError < Error; end
    class SerializationError < Error; end
    class UnsupportedBackendError < Error; end
    class TransactionError < Error; end
  end
end
