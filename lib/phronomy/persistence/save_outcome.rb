# frozen_string_literal: true

module Phronomy
  class Persistence
    # Classifies evidence supplied by the owning domains. No retry, callback,
    # ownership release or external operation is performed here.
    # @api public
    SaveOutcome = Data.define(:disposition, :original_error, :read_error) do
      def self.compare(before:, after:, original_error: nil)
        current = yield
        disposition = if current == after
          :committed
        elsif current == before
          :not_committed
        else
          :unknown
        end
        new(disposition: disposition, original_error: original_error, read_error: nil)
      rescue => error
        new(disposition: :unknown, original_error: original_error, read_error: error)
      end
    end
  end
end
