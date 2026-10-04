# frozen_string_literal: true

require_relative "transport_error"

module Phronomy
  module LLMAdapter
    class RateLimitError < TransportError; end
  end
end
