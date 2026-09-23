# frozen_string_literal: true

module Phronomy
  module Storage
    # A neutral storage contract failure.
    # @api public
    class BlobConflictError < ConflictError
    end
  end
end
