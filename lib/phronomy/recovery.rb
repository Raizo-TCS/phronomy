# frozen_string_literal: true

module Phronomy
  # Small private Recovery semantic/primitives layer shared by Agent and
  # Workflow recovery. Entity-specific orchestration remains outside this module.
  # @api private
  module Recovery
    RESUMABLE = :resumable
    RECONCILABLE = :reconcilable
    RESOLUTION_REQUIRED = :resolution_required
    DISPOSITIONS = [RESUMABLE, RECONCILABLE, RESOLUTION_REQUIRED].freeze

    ALLOWED_OUTCOMES = %i[succeeded failed not_performed].freeze
    # Internal shorthand used by the Agent Recovery implementation. This is not
    # a public API constant; both names refer to the same frozen value.
    OUTCOMES = ALLOWED_OUTCOMES

    MISSING = Object.new.freeze

    Classification = Data.define(
      :disposition, :reason, :subject, :allowed_outcomes, :facts
    ) do
      def initialize(
        disposition:,
        reason:,
        subject: nil,
        allowed_outcomes: [],
        facts: {}
      )
        normalized = disposition.to_sym
        unless Phronomy::Recovery::DISPOSITIONS.include?(normalized)
          raise ArgumentError, "unknown Recovery disposition: #{disposition.inspect}"
        end
        super(
          disposition: normalized,
          reason: reason.to_sym,
          subject: subject && Phronomy::Recovery.normalize_subject(subject),
          allowed_outcomes: Array(allowed_outcomes).map(&:to_sym).freeze,
          facts: Phronomy::Agent::Immutable.copy(facts || {})
        )
      end
    end

    module_function

    def normalize_outcome(outcome)
      normalized = outcome.to_sym
      unless OUTCOMES.include?(normalized)
        raise ArgumentError, "unsupported Recovery outcome: #{outcome.inspect}"
      end
      normalized
    end

    def validate_resolution_material!(outcome:, result_present:, error_present:)
      normalized = normalize_outcome(outcome)
      case normalized
      when :succeeded
        raise ArgumentError, "Recovery :succeeded forbids error:" if error_present
      when :failed
        raise ArgumentError, "Recovery :failed requires error:" unless error_present
        raise ArgumentError, "Recovery :failed forbids result:" if result_present
      when :not_performed
        if result_present || error_present
          raise ArgumentError, "Recovery :not_performed accepts neither result: nor error:"
        end
      end
      true
    end

    def normalize_subject(subject)
      hash = subject.to_h.transform_keys(&:to_sym)
      type = hash.fetch(:type).to_sym
      normalized = {type: type}
      case type
      when :llm_call
        normalized[:llm_call_id] = required_id(hash, :llm_call_id)
      when :tool_invocation
        normalized[:tool_invocation_id] = required_id(hash, :tool_invocation_id)
      when :persistence_operation
        # Persistence operation references are structural only. Do not introduce
        # a generic durable operation/recovery identity here.
        normalized[:entity] = hash.fetch(:entity).to_sym
      else
        raise ArgumentError, "unsupported Recovery subject type: #{type.inspect}"
      end
      normalized.freeze
    end

    def subject_key(subject)
      normalized = normalize_subject(subject)
      case normalized.fetch(:type)
      when :llm_call
        "llm_call:#{normalized.fetch(:llm_call_id)}"
      when :tool_invocation
        "tool_invocation:#{normalized.fetch(:tool_invocation_id)}"
      when :persistence_operation
        "persistence_operation:#{normalized.fetch(:entity)}"
      end
    end

    def subject_equal?(left, right)
      normalize_subject(left) == normalize_subject(right)
    rescue ArgumentError, KeyError
      false
    end

    # Compare authoritative current state with a known pre/post revision pair.
    # This is deliberately small: callers still validate entity-specific content.
    def compare_revisions(current_revision:, expected_pre_revision:, intended_post_revision:)
      current = current_revision
      return :post_state if current == intended_post_revision
      return :pre_state if current == expected_pre_revision

      :conflict
    end

    # Generic F1 helper for revisioned snapshot repositories such as Workflow.
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

    def required_id(hash, key)
      value = hash.fetch(key)
      text = value.to_s
      raise ArgumentError, "#{key} must not be empty" if text.empty?

      text.freeze
    end
    private_class_method :required_id
  end
end
