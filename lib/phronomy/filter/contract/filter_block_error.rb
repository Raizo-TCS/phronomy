# frozen_string_literal: true

require_relative "../../common/error"

module Phronomy
  class FilterBlockError < Error
    attr_reader :filter

    def initialize(message, filter: nil)
      super(message)
      @filter = filter
    end
  end
end
