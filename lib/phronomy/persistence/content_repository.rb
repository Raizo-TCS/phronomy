# frozen_string_literal: true

module Phronomy
  class Persistence
    # Domain-facing content access uses the Persistence failure vocabulary.
    # ContentStore implementations retain their independent backend contract.
    # @api private
    class ContentRepository < Phronomy::ContentStore::Base
      def initialize(store)
        @store = store
      end

      def put(bytes, canonicalization_version:)
        StorageBoundary.call { @store.put(bytes, canonicalization_version: canonicalization_version) }
      end

      def fetch(content_id)
        StorageBoundary.call { @store.fetch(content_id) }
      end

      def exist?(content_id)
        StorageBoundary.call { @store.exist?(content_id) }
      end
    end
  end
end
