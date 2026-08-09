# frozen_string_literal: true

require "time"

module Phronomy
  module Agent
    class AgentRoot
      LIFECYCLE_STATUSES = %i[idle active suspended closed invalidated].freeze

      ATTRIBUTES = %i[
        agent_id agent_definition_id definition_version agent_revision
        context_revision journal_position lifecycle_status transcript_generation
        created_at updated_at metadata
      ].freeze

      attr_reader(*ATTRIBUTES)

      def self.create(agent_id:, agent_definition_id:, definition_version:, metadata: {})
        now = Time.now.utc.iso8601(6)
        new(
          agent_id: agent_id,
          agent_definition_id: agent_definition_id,
          definition_version: definition_version,
          agent_revision: 0,
          context_revision: 0,
          journal_position: 0,
          lifecycle_status: :idle,
          transcript_generation: 0,
          created_at: now,
          updated_at: now,
          metadata: metadata
        )
      end

      def initialize(**attributes)
        ATTRIBUTES.each do |name|
          value = attributes.fetch(name)
          value = value.to_sym if name == :lifecycle_status
          instance_variable_set("@#{name}", Immutable.copy(value))
        end
        unless LIFECYCLE_STATUSES.include?(lifecycle_status)
          raise ArgumentError, "unknown Agent lifecycle status: #{lifecycle_status.inspect}"
        end
        raise ArgumentError, "agent_revision must be non-negative" if agent_revision.negative?
        raise ArgumentError, "context_revision must be non-negative" if context_revision.negative?
        raise ArgumentError, "journal_position must be non-negative" if journal_position.negative?
        Immutable.validate_canonical_json!(metadata, label: "Agent metadata")
        freeze
      end

      def with(**changes)
        values = to_h.transform_keys(&:to_sym).merge(changes)
        values[:updated_at] = Time.now.utc.iso8601(6) unless changes.key?(:updated_at)
        self.class.new(**values)
      end

      def to_h
        ATTRIBUTES.to_h { |name| [name.to_s, public_send(name)] }
      end

      def self.from_h(hash)
        new(**ATTRIBUTES.to_h { |name| [name, hash.fetch(name.to_s)] })
      end
    end
  end
end
