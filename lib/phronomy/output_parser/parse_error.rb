# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  class ParseError < Error
    # @api public
    attr_reader :details

    # @api public
    def initialize(message = nil, code: nil, details: [])
      @details = Phronomy::Values::Immutable.json(details)
      super(message, code: code)
    end
  end
end
