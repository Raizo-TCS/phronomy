# frozen_string_literal: true

module Phronomy
  class Persistence
    # Compares revision and snapshot evidence supplied by the owning domain.
    # Does not load, save, retry, resolve external operations or decide resumption.
    # @api private
    module SnapshotComparison
      module_function

      # Compare authoritative current state with a known pre/post revision pair.
      # This is deliberately small: callers still validate entity-specific content.
      def compare_revisions(current_revision:, expected_pre_revision:, intended_post_revision:)
        current = current_revision
        return :post_state if current == intended_post_revision
        return :pre_state if current == expected_pre_revision

        :conflict
      end

      # Evidence comparison for revisioned snapshot repositories.
      # Some repositories return a newly allocated revision only after save, so
      # callers may not know the intended post revision in advance. In that case
      # the intended snapshot plus a revision different from the expected pre
      # revision identifies the post-state.
      def compare_revisioned_snapshot(
        record:,
        expected_pre_revision:,
        intended_snapshot:,
        intended_post_revision: nil
      )
        return :pre_state if record.nil? && expected_pre_revision.nil?
        return :conflict if record.nil?

        revision = fetch_value(record, :revision)
        snapshot = fetch_value(record, :snapshot)
        normalized_snapshot = normalize_value(snapshot)
        normalized_intended = normalize_value(intended_snapshot)

        if intended_post_revision
          if revision == intended_post_revision &&
              normalized_snapshot == normalized_intended
            return :post_state
          end
        elsif normalized_snapshot == normalized_intended &&
            revision != expected_pre_revision
          return :post_state
        end

        return :pre_state if revision == expected_pre_revision

        :conflict
      end

      def normalize_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            result[key.to_s] = normalize_value(child)
          end
        when Array
          value.map { |child| normalize_value(child) }
        when Symbol
          value.to_s
        else
          value
        end
      end

      def fetch_value(record, key)
        return nil unless record
        return record.public_send(key) if record.respond_to?(key)
        return record[key] if record.respond_to?(:key?) && record.key?(key)
        string_key = key.to_s
        return record[string_key] if record.respond_to?(:key?) && record.key?(string_key)

        nil
      end
    end
  end
end
