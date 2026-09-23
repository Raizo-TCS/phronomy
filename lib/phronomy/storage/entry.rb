# frozen_string_literal: true

module Phronomy
  module Storage
    # Values crossing the driver boundary never expose mutable storage state.
    # @api public
    module Entry
      Record = Data.define(:key, :revision, :attributes, :record) do
        def initialize(key:, revision:, attributes:, record:)
          super(key: Validation.key(key), revision: Validation.revision(revision),
                attributes: Validation.attributes(attributes), record: Validation.record(record))
        end
      end
      Append = Data.define(:id, :record) do
        def initialize(id:, record:)
          super(id: Validation.key(id), record: Validation.record(record))
        end
      end
      Stream = Data.define(:position, :id, :record) do
        def initialize(position:, id:, record:)
          super(position: Validation.revision(position), id: Validation.key(id), record: Validation.record(record))
        end
      end
      Blob = Data.define(:key, :bytes, :attributes) do
        def initialize(key:, bytes:, attributes:)
          raise ArgumentError, "blob bytes must be a String" unless bytes.is_a?(String)
          super(key: Validation.key(key), bytes: bytes.dup.force_encoding(Encoding::BINARY).freeze,
                attributes: Validation.attributes(attributes))
        end
      end
    end
  end
end
