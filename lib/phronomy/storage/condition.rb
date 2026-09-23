# frozen_string_literal: true

module Phronomy
  module Storage
    # A deliberately closed set of conditions; no payload predicates or callbacks.
    # @api public
    module Condition
      RevisionIs = Data.define(:resource, :key, :expected) do
        def initialize(resource:, key:, expected:)
          super(resource: Resource.normalize_reference(resource), key: Validation.key(key), expected: Validation.revision(expected))
        end
      end
      StreamHeadIs = Data.define(:resource, :stream, :expected) do
        def initialize(resource:, stream:, expected:)
          super(resource: Resource.normalize_reference(resource), stream: Validation.key(stream), expected: Validation.revision(expected))
        end
      end
      NoRows = Data.define(:resource, :index, :equals) do
        def initialize(resource:, index:, equals:)
          super(resource: Resource.normalize_reference(resource), index: index, equals: Validation.immutable(equals))
        end
      end
    end
  end
end
