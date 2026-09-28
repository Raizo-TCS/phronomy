# frozen_string_literal: true

module Phronomy
  module ContentStore
    # Resources owned by the content service and supplied to Storage composition.
    # @api private
    module StorageSchema
      CONTENTS = Phronomy::Storage::Resource.new(id: "content.blobs", kind: :blobs,
        attributes: {canonicalization_version: :integer})
    end
  end
end
