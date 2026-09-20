# frozen_string_literal: true

require_relative "transport_error"

module Phronomy
  class AuthenticationError < TransportError; end
end
