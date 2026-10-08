# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  module LLMAdapter
    class ContextLengthError < Phronomy::Error; end
  end
end
