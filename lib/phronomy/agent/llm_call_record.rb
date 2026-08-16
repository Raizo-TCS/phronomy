# frozen_string_literal: true

require "securerandom"
require "time"

module Phronomy
  module Agent
    class LLMCallRecord
      STATUSES = %i[completed failed cancelled].freeze

      ATTRIBUTES = %i[
        llm_call_id execution_id sequence status manifest_ref output_ref
        error_ref usage_ref started_at completed_at metadata
      ].freeze
      attr_reader(*ATTRIBUTES)

      def initialize(
        execution_id:,
        sequence:,
        status:,
        manifest_ref:,
        llm_call_id: SecureRandom.uuid,
        output_ref: nil,
        error_ref: nil,
        usage_ref: nil,
        started_at: Time.now.utc.iso8601(6),
        completed_at: nil,
        metadata: {}
      )
        values = binding.local_variables.to_h { |name| [name, binding.local_variable_get(name)] }
        ATTRIBUTES.each do |name|
          value = values.fetch(name)
          value = value.to_sym if name == :status
          instance_variable_set("@#{name}", Immutable.copy(value))
        end
        raise ArgumentError, "unknown LLM Call status: #{status.inspect}" unless STATUSES.include?(status)
        raise ArgumentError, "LLM Call sequence must be positive" unless sequence.positive?
        Immutable.validate_canonical_json!(metadata, label: "LLM Call metadata")
        freeze
      end

      # Returns the canonical durable representation of this LLM Call record.
      #
      # @return [Hash{String => Object}]
      # @api public
      def to_h
        ATTRIBUTES.to_h do |name|
          value = public_send(name)
          value = value.to_s if name == :status
          [name.to_s, value]
        end
      end

      # Restores an LLM Call record from its canonical durable representation.
      # String and Symbol top-level keys are accepted so database adapters may
      # pass either a parsed JSON object or a Ruby-native Hash.
      #
      # @param hash [Hash]
      # @return [LLMCallRecord]
      # @api public
      def self.from_h(hash)
        attributes = ATTRIBUTES.to_h do |name|
          key = hash.key?(name.to_s) ? name.to_s : name
          [name, hash.fetch(key)]
        end
        attributes[:status] = attributes.fetch(:status).to_sym
        new(**attributes)
      end
    end
  end
end
