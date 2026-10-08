# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module VectorStore
    # A backend could not produce a valid synchronous result. This includes
    # malformed external responses that must not be replaced with success values.
    # @api public
    class InvalidResultError < Phronomy::Error; end
  end
end
