# frozen_string_literal: true

module Phronomy
  module ContentStore
    # @api private
    module StorageSchema
      CONTENTS = Phronomy::Storage::Resource.new(id: "content.blobs", kind: :blobs,
        attributes: {canonicalization_version: :integer})
    end
  end
end
