# frozen_string_literal: true

module Phronomy
  module Storage
    # A neutral storage contract failure.
    # @api public
    class ConditionFailedError < ConflictError
      attr_reader :condition
      # @api public
      def initialize(condition, code: nil)
        @condition = condition
        super("storage condition failed: #{condition.class.name}", code: code)
      end
    end
  end
end
