# frozen_string_literal: true

module Phronomy
  module Storage
    # A stable existing record used as a transaction lock anchor.
    # @api public
    GuardRef = Data.define(:resource, :key) do
      def initialize(resource:, key:)
        super(resource: Validation.reference(resource), key: Validation.key(key))
      end
    end
  end
end
