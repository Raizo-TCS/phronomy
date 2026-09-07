# frozen_string_literal: true

require "time"

module Phronomy
  module MultiAgent
    # Immutable current-format semantic record; contains no Runtime handles.
    # @api private
    class TeamRoot
      ATTRIBUTES = %w[team_id team_definition_id team_definition_version team_revision lifecycle_status created_at updated_at metadata].freeze
      attr_reader(*ATTRIBUTES)

      def initialize(**values)
        source = values.transform_keys(&:to_s)
        raise ArgumentError, "TeamRoot schema mismatch" unless source.keys.sort == ATTRIBUTES.sort
        canonical = Phronomy::CanonicalJSON.load(Phronomy::CanonicalJSON.dump(source))
        ATTRIBUTES.each { |key| instance_variable_set("@#{key}", Phronomy::Agent::Immutable.copy(canonical.fetch(key))) }
        raise ArgumentError, "missing team_id" if team_id.to_s.empty?
        raise ArgumentError, "invalid team_revision" unless team_revision.is_a?(Integer) && team_revision >= 0
        raise ArgumentError, "invalid metadata" unless metadata.is_a?(Hash)
        raise ArgumentError, "invalid Team lifecycle" unless %w[idle active closed].include?(lifecycle_status)
        raise ArgumentError, "missing Team definition" if team_definition_id.to_s.empty?
        raise ArgumentError, "invalid Team version" unless team_definition_version.is_a?(Integer) && team_definition_version.positive?
        freeze
      end

      def to_h = ATTRIBUTES.to_h { |key| [key, public_send(key)] }.freeze

      def self.from_h(value)
        new(**value.transform_keys(&:to_sym))
      end

      def with(**changes)
        values = to_h.merge(changes.transform_keys(&:to_s))
        values["team_revision"] = team_revision + 1 unless changes.key?(:team_revision)
        values["updated_at"] = Time.now.utc.iso8601(6) unless changes.key?(:updated_at)
        self.class.from_h(values)
      end
    end
  end
end
