# frozen_string_literal: true

module Phronomy
  module Storage
    # Atomic ordered append with a per-stream head and entry identity.
    # @api public
    class Streams
      attr_reader :resource
      def initialize(view, resource) = (@view, @resource = view, resource)

      # @api public
      def append(stream:, expected_head:, entries:)
        @view.validate!
        key = Validation.key(stream)
        expected = Validation.revision(expected_head)
        raise ArgumentError, "entries must be an Array" unless entries.is_a?(Array)
        values = entries.map do |entry|
          raise SerializationError, "expected Entry::Append" unless entry.is_a?(Entry::Append)
          Entry::Append.new(id: entry.id, record: entry.record)
        end
        raise ConflictError, "duplicate stream entry identity" unless values.map(&:id).uniq.length == values.length
        @view.perform(:append_stream, resource, stream: key, expected_head: expected, entries: values.freeze)
      end

      # @api public
      def read(stream:, after: 0, limit: nil)
        @view.validate!
        @view.perform(:read_stream, resource, stream: Validation.key(stream), after: Validation.revision(after), limit: Validation.limit(limit))
      end

      # @api public
      def head(stream:)
        @view.validate!
        @view.perform(:stream_head, resource, stream: Validation.key(stream))
      end

      # @api public
      def delete(stream:)
        @view.validate!
        @view.perform(:delete_stream, resource, stream: Validation.key(stream))
      end
    end
  end
end
