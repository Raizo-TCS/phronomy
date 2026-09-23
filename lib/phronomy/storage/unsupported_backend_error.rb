# frozen_string_literal: true

module Phronomy
  module Storage
    # A backend does not provide a required storage capability.
    # @api public
    class UnsupportedBackendError < Phronomy::Error; end
  end
end
