# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module Embeddings
    # An embedding provider failed; the original SDK exception remains #cause.
    # @api public
    class TransportError < Phronomy::Error; end
  end
end
