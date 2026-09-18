# frozen_string_literal: true

module Phronomy
  module Storage
    # A value cannot be represented by the storage record contract.
    # @api public
    class SerializationError < Phronomy::Error; end
  end
end
