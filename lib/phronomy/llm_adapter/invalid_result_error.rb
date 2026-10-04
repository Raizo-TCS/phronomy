# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module LLMAdapter
    # @api public
    class InvalidResultError < Phronomy::Error; end
  end
end
