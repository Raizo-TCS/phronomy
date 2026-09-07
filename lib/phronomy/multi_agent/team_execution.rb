# frozen_string_literal: true

require "time"

module Phronomy
  module MultiAgent
    # Immutable current-format semantic record; contains no Runtime handles.
    # @api private
    class TeamExecution
      ATTRIBUTES = %w[team_execution_id team_id execution_revision status phase input_ref coordinator tasks workers assignments result_ref error_ref created_at updated_at metadata].freeze
      attr_reader(*ATTRIBUTES)

      def initialize(**values)
        source = values.transform_keys(&:to_s)
        raise ArgumentError, "TeamExecution schema mismatch" unless source.keys.sort == ATTRIBUTES.sort
        canonical = Phronomy::CanonicalJSON.load(Phronomy::CanonicalJSON.dump(source))
        ATTRIBUTES.each { |key| instance_variable_set("@#{key}", Phronomy::Agent::Immutable.copy(canonical.fetch(key))) }
        raise ArgumentError, "missing team_execution_id" if team_execution_id.to_s.empty?
        raise ArgumentError, "invalid execution_revision" unless execution_revision.is_a?(Integer) && execution_revision >= 0
        raise ArgumentError, "invalid metadata" unless metadata.is_a?(Hash)
        raise ArgumentError, "invalid Team status" unless %w[active completed failed cancelled].include?(status)
        raise ArgumentError, "missing Team owner" if team_id.to_s.empty?
        raise ArgumentError, "invalid Team collections" unless [tasks, workers, assignments].all? { |v| v.is_a?(Array) } && coordinator.is_a?(Hash)
        freeze
      end

      def to_h = ATTRIBUTES.to_h { |key| [key, public_send(key)] }.freeze

      def self.from_h(value)
        new(**value.transform_keys(&:to_sym))
      end

      def with(**changes)
        values = to_h.merge(changes.transform_keys(&:to_s))
        values["execution_revision"] = execution_revision + 1 unless changes.key?(:execution_revision)
        values["updated_at"] = Time.now.utc.iso8601(6) unless changes.key?(:updated_at)
        self.class.from_h(values)
      end

      def active? = status == "active"
      def terminal? = %w[completed failed cancelled].include?(status)
    end
  end
end
