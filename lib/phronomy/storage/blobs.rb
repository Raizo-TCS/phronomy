# frozen_string_literal: true

module Phronomy
  module Storage
    # Immutable byte values sharing the same transaction domain as other resources.
    # @api public
    class Blobs
      attr_reader :resource
      def initialize(view, resource) = (@view, @resource = view, resource)

      # @api public
      def put_if_absent(key:, bytes:, attributes:)
        @view.validate!
        blob = Entry::Blob.new(key: key, bytes: bytes, attributes: resource.validate_attributes(attributes))
        @view.perform(:put_blob, resource, blob: blob)
      end

      # @api public
      def fetch(key)
        @view.validate!
        @view.perform(:fetch_blob, resource, key: Validation.key(key))
      end

      # @api public
      def exist?(key)
        @view.validate!
        @view.perform(:blob_exists, resource, key: Validation.key(key))
      end
    end
  end
end
