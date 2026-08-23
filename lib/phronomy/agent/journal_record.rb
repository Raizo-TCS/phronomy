# frozen_string_literal: true

require "securerandom"
require "time"

module Phronomy
  module Agent
    # One immutable entry in the Agent's append-only Canonical Complete Execution Log.
    #
    # Raw logical execution facts are never rewritten for Context selection or
    # compaction. Derived Context artifacts must be appended separately and keep
    # stable provenance back to their raw source records.
    class JournalRecord
      ATTRIBUTES = %i[
        record_id agent_id sequence execution_id llm_call_id kind channel role content_ref
        parent_id causation_id visibility context_generation
        context_candidate occurred_at metadata
      ].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(
        agent_id:,
        kind:,
        channel:,
        record_id: SecureRandom.uuid,
        sequence: nil,
        execution_id: nil,
        llm_call_id: nil,
        role: nil,
        content_ref: nil,
        parent_id: nil,
        causation_id: nil,
        visibility: :agent,
        context_generation: 0,
        context_candidate: false,
        occurred_at: Time.now.utc.iso8601(6),
        metadata: {}
      )
        values = binding.local_variables.to_h { |name| [name, binding.local_variable_get(name)] }
        ATTRIBUTES.each do |name|
          value = values.fetch(name)
          value = value.to_sym if %i[kind channel role visibility].include?(name) && value
          instance_variable_set("@#{name}", Immutable.copy(value))
        end
        Immutable.validate_canonical_json!(metadata, label: "Journal metadata")
        freeze
      end

      def with_sequence(sequence)
        self.class.from_h(to_h.merge("sequence" => sequence))
      end

      def to_h
        ATTRIBUTES.to_h { |name| [name.to_s, public_send(name)] }
      end

      def self.from_h(hash)
        # Decode only current canonical attributes. This intentionally lets
        # legacy durable Hashes carry removed correlation_id without restoring it.
        new(**ATTRIBUTES.to_h do |name|
          key = hash.key?(name.to_s) ? name.to_s : name
          [name, hash[key]]
        end)
      end
    end
  end
end
