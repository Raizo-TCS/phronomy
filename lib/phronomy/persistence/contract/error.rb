# frozen_string_literal: true

require_relative "../../common/error"

module Phronomy
  class Persistence
    # Base for domain-facing Persistence failures. Not every Error implies a known rollback.
    # @api public
    class Error < Phronomy::Error; end
  end
end
