# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  class LowConfidenceError < Error
    attr_reader :result

    def initialize(result, code: nil)
      @result = result
      super("Answer confidence #{result.confidence} is below the required threshold", code: code)
    end
  end
end
