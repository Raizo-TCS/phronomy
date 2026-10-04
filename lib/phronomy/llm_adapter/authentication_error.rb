# frozen_string_literal: true

require_relative "transport_error"

module Phronomy
  module LLMAdapter
    class AuthenticationError < TransportError; end
  end
end
