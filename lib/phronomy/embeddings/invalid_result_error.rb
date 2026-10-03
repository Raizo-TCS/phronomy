# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module Embeddings
    # A provider returned data that violates the embedding result contract.
    # @api public
    class InvalidResultError < Phronomy::Error; end
  end
end
