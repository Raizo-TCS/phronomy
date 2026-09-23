# frozen_string_literal: true

module Phronomy
  module Storage
    # A storage identity, revision, or position precondition failed.
    # @api public
    class ConflictError < Phronomy::Error; end
  end
end
