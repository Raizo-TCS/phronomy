# frozen_string_literal: true

module Phronomy
  module ContentStore
    # Content identity and digest validation belong to ContentStore, not Blobs.
    # @api private
    class StoredContents < Base
      def initialize(view) = @view = view

      def put(bytes, canonicalization_version:)
        value = String(bytes).b
        id = content_id_for(value)
        @view.atomic do |bound|
          blob = bound.blobs(StorageSchema::CONTENTS).put_if_absent(key: id, bytes: value,
            attributes: {canonicalization_version: Integer(canonicalization_version)})
          verify!(blob, id)
          id
        end
      rescue Phronomy::Storage::BlobConflictError => error
        raise IntegrityError, error.message
      end

      def fetch(content_id)
        id = content_id.to_s
        @view.atomic do |bound|
          blob = bound.blobs(StorageSchema::CONTENTS).fetch(id)
          verify!(blob, id)
          blob.bytes.dup
        end
      end

      def exist?(content_id) = @view.blobs(StorageSchema::CONTENTS).exist?(content_id.to_s)

      private

      def verify!(blob, id)
        unless blob.key == id && content_id_for(blob.bytes) == id
          raise IntegrityError, "content digest mismatch: #{id}"
        end
      end
    end
  end
end
