# frozen_string_literal: true

require_relative "error"

module Phronomy
  class Persistence
    # The selected backend cannot satisfy a required Persistence capability.
    # @api public
    class UnsupportedBackendError < Error; end
  end
end
