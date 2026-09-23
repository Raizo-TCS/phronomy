# frozen_string_literal: true

require_relative "transport_error"

module Phronomy
  class RateLimitError < TransportError; end
end
