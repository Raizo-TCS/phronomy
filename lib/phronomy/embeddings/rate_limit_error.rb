# frozen_string_literal: true

require_relative "transport_error"

module Phronomy
  module Embeddings
    # Provider refusal; this classification alone does not authorize retries.
    # @api public
    class RateLimitError < TransportError; end
  end
end
