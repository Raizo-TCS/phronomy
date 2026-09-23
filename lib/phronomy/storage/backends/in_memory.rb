# frozen_string_literal: true

require "monitor"

module Phronomy
  module Storage
    module Backends
      # One Monitor and snapshot cover every declared resource and nested scope.
      # @api public
      class InMemory < Backend
        # @api public
        def initialize(resources: [])
          super
          @monitor = Monitor.new
          @state = resources.to_h { |resource| [resource.id, {}] }
        end

        # @api public
        def capabilities = REQUIRED_CAPABILITIES

        private

        def storage_transaction
          @monitor.synchronize do
            snapshot = Marshal.load(Marshal.dump(@state))
            completed = false
            begin
              result = yield @state
              completed = true
              result
            ensure
              @state.replace(snapshot) unless completed
            end
          end
        end

        def bucket(state, resource) = state.fetch(resource.id)

        def read_record(state, resource, key:)
          value = bucket(state, resource)[key]
          value && Entry::Record.new(**value.to_h)
        end

        def lock_guard(state, resource, key:)
          raise NotFoundError, "guard record not found: #{resource.id}/#{key}" unless bucket(state, resource).key?(key)
          true
        end

        def guard_record(state, resource, key:, attributes: {}, creating: false)
          guard = resource.guard
          return unless guard
          anchor = resources.fetch(guard.fetch(:resource))
          return if creating && anchor.equal?(resource) && guard[:via] == :key
          guard_key = [:key, :stream].include?(guard[:via]) ? key : attributes.fetch(guard[:via])
          lock_guard(state, anchor, key: guard_key)
        end

        def check_unique(state, resource, entry)
          resource.unique.each do |constraint|
            next if constraint[:fields].any? { |key| entry.attributes[key].nil? }
            next unless constraint.fetch(:where).all? { |key, value| entry.attributes[key] == value }
            conflict = bucket(state, resource).values.any? do |other|
              other.key != entry.key && constraint[:where].all? { |k, val| other.attributes[k] == val } && constraint[:fields].all? { |k| other.attributes[k] == entry.attributes[k] }
            end
            raise UniqueConstraintError.new(resource: resource, constraint: constraint[:name]) if conflict
          end
        end

        def insert_record(state, resource, entry:)
          raise ConflictError, "duplicate record identity" if bucket(state, resource).key?(entry.key)
          guard_record(state, resource, key: entry.key, attributes: entry.attributes, creating: true)
          check_unique(state, resource, entry)
          bucket(state, resource)[entry.key] = entry
          Entry::Record.new(**entry.to_h)
        end

        def replace_record(state, resource, entry:, expected_revision:, expected_attributes:)
          current = bucket(state, resource)[entry.key] || raise(NotFoundError, "record not found: #{entry.key}")
          guard_record(state, resource, key: entry.key, attributes: current.attributes)
          raise ConflictError, "record revision conflict" unless current.revision == expected_revision
          unless expected_attributes.all? { |key, value| current.attributes[key] == value } && resource.immutable_attributes.all? { |key| current.attributes[key] == entry.attributes[key] }
            raise ConflictError, "record attribute precondition failed"
          end
          check_unique(state, resource, entry)
          bucket(state, resource)[entry.key] = entry
          Entry::Record.new(**entry.to_h)
        end

        def delete_record(state, resource, key:, expected_revision:)
          current = bucket(state, resource)[key]
          if !expected_revision.equal?(Records::UNCHECKED) && (!current || current.revision != expected_revision)
            raise ConflictError, "record deletion revision conflict"
          end
          return nil unless current
          guard_record(state, resource, key: key, attributes: current.attributes)
          bucket(state, resource).delete(key)
          nil
        end

        def scan_records(state, resource, equals:, after:, limit:)
          entries = bucket(state, resource).values.select { |entry| (!after || entry.key.b > after.b) && equals.all? { |key, value| entry.attributes[key] == value } }.sort_by { |entry| entry.key.b }
          entries = entries.first(limit) if limit
          entries.map { |entry| Entry::Record.new(**entry.to_h) }.freeze
        end

        def delete_matching_records(state, resource, equals:)
          if resource.guard && ![:key, :stream].include?(resource.guard[:via])
            raise ArgumentError, "deletion must constrain its guard attribute" unless equals.key?(resource.guard[:via])
            guard_record(state, resource, key: "unused", attributes: equals)
          end
          scan_records(state, resource, equals: equals, after: nil, limit: nil).each do |entry|
            delete_record(state, resource, key: entry.key, expected_revision: Records::UNCHECKED)
          end
          nil
        end

        def append_stream(state, resource, stream:, expected_head:, entries:)
          guard_record(state, resource, key: stream)
          stored = bucket(state, resource).fetch(stream, [])
          raise ConflictError, "stream head conflict" unless stored.length == expected_head
          raise ConflictError, "duplicate stream entry identity" unless (stored.map(&:id) & entries.map(&:id)).empty?
          appended = entries.each_with_index.map { |entry, index| Entry::Stream.new(position: expected_head + index + 1, id: entry.id, record: entry.record) }
          bucket(state, resource)[stream] = stored + appended unless appended.empty?
          appended.map { |entry| Entry::Stream.new(**entry.to_h) }.freeze
        end

        def read_stream(state, resource, stream:, after:, limit:)
          selected = bucket(state, resource).fetch(stream, []).select { |entry| entry.position > after }
          selected = selected.first(limit) if limit
          selected.map { |entry| Entry::Stream.new(**entry.to_h) }.freeze
        end

        def stream_head(state, resource, stream:) = bucket(state, resource).fetch(stream, []).length

        def delete_stream(state, resource, stream:)
          guard_record(state, resource, key: stream)
          bucket(state, resource).delete(stream)
          nil
        end

        def put_blob(state, resource, blob:)
          stored = bucket(state, resource)[blob.key]
          raise BlobConflictError, "blob bytes are immutable" if stored && stored.bytes != blob.bytes
          stored ||= bucket(state, resource)[blob.key] = blob
          Entry::Blob.new(**stored.to_h)
        end

        def fetch_blob(state, resource, key:)
          stored = bucket(state, resource)[key] || raise(NotFoundError, "blob not found: #{key}")
          Entry::Blob.new(**stored.to_h)
        end

        def blob_exists(state, resource, key:) = bucket(state, resource).key?(key)
      end
    end
  end
end
