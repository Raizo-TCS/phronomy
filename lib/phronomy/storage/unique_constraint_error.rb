# frozen_string_literal: true

module Phronomy
  module Storage
    # A neutral storage contract failure.
    # @api public
    class UniqueConstraintError < ConflictError
      attr_reader :resource, :constraint
      # @api public
      def initialize(resource:, constraint:, code: nil)
        @resource = resource.id
        @constraint = constraint
        super("unique constraint #{resource.id}.#{constraint} failed", code: code)
      end
    end
  end
end
