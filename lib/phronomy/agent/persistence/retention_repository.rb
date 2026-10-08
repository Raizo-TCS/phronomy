# frozen_string_literal: true

require "digest"

module Phronomy
  module Agent
    module Persistence
      # @api private
      class RetentionRepository
        include Phronomy::Storage::RecordCodec

        def initialize(view) = @view = view

        def retain(retention)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |view|
              guard!(view, retention.agent_id)
              records = view.records(StorageSchema::RETENTIONS)
              key = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(retention.to_h))
              if (existing = records.read(key))
                raise Phronomy::Storage::SerializationError, "retention identity mismatch" unless decode(existing) == retention
              else
                records.insert(key: key, revision: 0,
                  attributes: {owner: retention.agent_id, holder: retention.owner_key},
                  record: build_record("phronomy.agent_retention", "0.1", retention.to_h))
              end
            end
          end
          retention
        end

        def list(agent_id)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic { |view| view.records(StorageSchema::RETENTIONS).scan(index: :owner, equals: {owner: agent_id}).map { |entry| decode(entry) }.freeze }
          end
        end

        def release(agent_id:, owner_key:)
          Phronomy::Persistence::StorageBoundary.call do
            @view.atomic do |view|
              guard!(view, agent_id)
              records = view.records(StorageSchema::RETENTIONS)
              records.scan(index: :owner, equals: {owner: agent_id}).each do |entry|
                value = decode(entry)
                records.delete(key: entry.key, expected_revision: entry.revision) if value.owner_key == owner_key
              end
            end
          end
          nil
        end

        private

        def guard!(view, id)
          view.check!(guards: [Phronomy::Storage::GuardRef.new(resource: StorageSchema::ROOTS, key: id)], conditions: [])
        end

        def decode(entry)
          payload = current_payload!(entry.record, record_type: "phronomy.agent_retention", format_version: "0.1",
            keys: %w[agent_id execution_id owner_key], label: "Agent retention")
          value = Retention.new(**payload.transform_keys(&:to_sym))
          unless entry.attributes == {owner: value.agent_id, holder: value.owner_key}
            raise Phronomy::Storage::SerializationError, "retention attributes mismatch"
          end
          value
        end
      end
    end
  end
end
