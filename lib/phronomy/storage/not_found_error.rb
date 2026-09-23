# frozen_string_literal: true

module Phronomy
  module Storage
    # A requested stored record does not exist.
    # @api public
    class NotFoundError < Phronomy::Error; end
  end
end
