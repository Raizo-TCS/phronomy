# frozen_string_literal: true

module Phronomy
  module Storage
    # Compare-and-write records and declared equality indexes.
    # @api public
    class Records
      UNCHECKED = Object.new.freeze
      attr_reader :resource
      def initialize(view, resource) = (@view, @resource = view, resource)

      # @api public
      def insert(key:, revision:, attributes:, record:)
        @view.validate!
        entry = Entry::Record.new(key: key, revision: revision, attributes: resource.validate_attributes(attributes), record: record)
        @view.perform(:insert_record, resource, entry: entry)
      end

      # @api public
      def read(key)
        @view.validate!
        @view.perform(:read_record, resource, key: Validation.key(key))
      end

      # @api public
      def fetch(key)
        read(key) || raise(NotFoundError, "record not found: #{resource.id}/#{key}")
      end

      # @api public
      def replace(key:, expected_revision:, next_revision:, attributes:, record:, expected_attributes: {})
        @view.validate!
        expected = Validation.revision(expected_revision)
        entry = Entry::Record.new(key: key, revision: next_revision, attributes: resource.validate_attributes(attributes), record: record)
        raise ConflictError, "replace must advance revision exactly once" unless next_revision == expected + 1
        expected_values = resource.validate_attributes(expected_attributes, partial: true)
        @view.perform(:replace_record, resource, entry: entry, expected_revision: expected, expected_attributes: expected_values)
      end

      # @api public
      def delete(key:, expected_revision: UNCHECKED)
        @view.validate!
        expected = expected_revision.equal?(UNCHECKED) ? UNCHECKED : Validation.revision(expected_revision)
        @view.perform(:delete_record, resource, key: Validation.key(key), expected_revision: expected)
      end

      # @api public
      def scan(index:, equals:, after: nil, limit: nil)
        @view.validate!
        values = resource.index_values(index, equals)
        @view.perform(:scan_records, resource, equals: values, after: after.nil? ? nil : Validation.key(after), limit: Validation.limit(limit))
      end

      # @api public
      def delete_matching(index:, equals:)
        @view.validate!
        @view.perform(:delete_matching_records, resource, equals: resource.index_values(index, equals))
      end
    end
  end
end
