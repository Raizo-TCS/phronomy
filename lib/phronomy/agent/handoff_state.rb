# frozen_string_literal: true

require "time"

module Phronomy
  module Agent
    # Immutable current-format semantic record; contains no Runtime handles.
    # @api private
    class HandoffState
      ATTRIBUTES = %w[main_agent_id handoff_revision active_agent_id active_handoff_context_ref phase pending_source_execution_id pending_target_execution_id created_at updated_at metadata].freeze
      attr_reader(*ATTRIBUTES)

      def initialize(**values)
        source = values.transform_keys(&:to_s)
        raise ArgumentError, "HandoffState schema mismatch" unless source.keys.sort == ATTRIBUTES.sort
        canonical = Phronomy::CanonicalJSON.load(Phronomy::CanonicalJSON.dump(source))
        ATTRIBUTES.each { |key| instance_variable_set("@#{key}", Phronomy::Agent::Immutable.copy(canonical.fetch(key))) }
        raise ArgumentError, "missing main_agent_id" if main_agent_id.to_s.empty?
        raise ArgumentError, "invalid handoff_revision" unless handoff_revision.is_a?(Integer) && handoff_revision >= 0
        raise ArgumentError, "invalid metadata" unless metadata.is_a?(Hash)
        raise ArgumentError, "invalid Handoff phase" unless %w[stable target_pending target_active].include?(phase)
        raise ArgumentError, "missing active Agent" if active_agent_id.to_s.empty?
        if phase != "stable" && pending_target_execution_id.to_s.empty?
          raise ArgumentError, "pending Handoff requires exact Target execution"
        end
        freeze
      end

      def to_h = ATTRIBUTES.to_h { |key| [key, public_send(key)] }.freeze

      def self.from_h(value)
        new(**value.transform_keys(&:to_sym))
      end

      def with(**changes)
        values = to_h.merge(changes.transform_keys(&:to_s))
        values["handoff_revision"] = handoff_revision + 1 unless changes.key?(:handoff_revision)
        values["updated_at"] = Time.now.utc.iso8601(6) unless changes.key?(:updated_at)
        self.class.from_h(values)
      end
    end
  end
end
