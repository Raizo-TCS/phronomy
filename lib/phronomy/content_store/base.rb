# frozen_string_literal: true

require "digest"

module Phronomy
  module ContentStore
    class IntegrityError < Phronomy::Error; end

    class Base
      def put(_bytes, canonicalization_version:) = raise(NotImplementedError)
      def fetch(_content_id) = raise(NotImplementedError)
      def exist?(_content_id) = raise(NotImplementedError)

      def put_text(text)
        value = String(text).encode(Encoding::UTF_8)
        raise ArgumentError, "invalid UTF-8 text" unless value.valid_encoding?

        put(value, canonicalization_version: 1)
      end

      def put_json(value)
        put(
          Phronomy::CanonicalJSON.dump(value),
          canonicalization_version: Phronomy::CanonicalJSON::VERSION
        )
      end

      def fetch_text(content_id)
        value = fetch(content_id).force_encoding(Encoding::UTF_8)
        unless value.valid_encoding?
          raise IntegrityError, "content is not UTF-8: #{content_id}"
        end
        value
      end

      def fetch_json(content_id)
        Phronomy::CanonicalJSON.load(fetch(content_id))
      end

      def fetch_many(content_ids)
        Array(content_ids).uniq.to_h { |content_id| [content_id, fetch(content_id)] }
      end

      private

      def content_id_for(bytes)
        "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      end
    end
  end
end
