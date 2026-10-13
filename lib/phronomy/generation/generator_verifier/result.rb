# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # Immutable, JSON-reconstructible facts about one generation attempt.
    # Acceptance is the configured evaluation outcome, not application publication.
    class Result
      FIELDS = %i[output confidence citations iterations review_notes
        confidence_threshold review_approved termination_reason interrupted_phase].freeze
      attr_reader(*FIELDS)

      def self.accepted?(confidence:, confidence_threshold:, review_approved:)
        review_approved == true && !confidence.nil? && confidence >= confidence_threshold
      end

      def self.from_h(hash)
        raise ArgumentError, "Result data must be a Hash" unless hash.is_a?(Hash)
        fields = hash.each_with_object({}) do |(key, value), result|
          unless key.is_a?(String) || key.is_a?(Symbol)
            raise ArgumentError, "Result keys must be String or Symbol"
          end
          key = key.to_sym
          raise ArgumentError, "duplicate Result field: #{key}" if result.key?(key)
          result[key] = value
        end
        raise ArgumentError, "unknown Result fields" unless (fields.keys - FIELDS).empty?
        new(**fields)
      end

      def initialize(output:, confidence:, citations:, iterations:, review_notes:,
        confidence_threshold:, review_approved:, termination_reason:, interrupted_phase: nil)
        @output = output&.dup&.freeze
        @confidence = score(confidence, optional: true)
        @confidence_threshold = score(confidence_threshold)
        @review_approved = review_approved
        @termination_reason = termination_reason.to_s.freeze
        @interrupted_phase = interrupted_phase&.to_s&.freeze
        @iterations = iterations
        @citations = Phronomy::Values::Immutable.copy(json_value(citations))
        @review_notes = Phronomy::Values::Immutable.copy(review_notes)
        validate!
        freeze
      end

      def accepted?
        @termination_reason == "accepted"
      end

      def to_h
        FIELDS.to_h { |field| [field, public_send(field)] }
      end

      def ==(other)
        other.instance_of?(self.class) && to_h == other.to_h
      end
      alias_method :eql?, :==

      def hash
        [self.class, to_h].hash
      end

      private

      def score(value, optional: false)
        return nil if optional && value.nil?
        unless value.is_a?(Numeric) && value.real? && value.to_f.finite? && (0.0..1.0).cover?(value)
          raise ArgumentError, "scores and threshold must be finite numbers in 0..1"
        end
        value.to_f
      end

      def json_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, child), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError, "citation keys must be String or Symbol"
            end
            key = key.to_s
            raise ArgumentError, "duplicate citation key: #{key}" if result.key?(key)
            result[key] = json_value(child)
          end
        when Array then value.map { |child| json_value(child) }
        else
          Phronomy::CanonicalJSON.dump(value)
          value
        end
      end

      def validate!
        unless @output.nil? || @output.is_a?(String)
          raise ArgumentError, "output must be a String or nil"
        end
        unless @iterations.is_a?(Integer) && @iterations >= 0
          raise ArgumentError, "iterations must be a nonnegative Integer"
        end
        unless @citations.is_a?(Array) && @citations.all?(Hash) &&
            @review_notes.is_a?(Array) && @review_notes.all?(String)
          raise ArgumentError, "citations must be hashes and review_notes must be strings"
        end
        if @termination_reason == "tool_rejected"
          unless %w[draft review].include?(@interrupted_phase) && @review_approved.nil? && @confidence.nil?
            raise ArgumentError, "tool rejection must identify its phase and has no completed evaluation"
          end
          return
        end
        unless @iterations.positive? && @output.is_a?(String) && !@confidence.nil? &&
            [true, false].include?(@review_approved) && @interrupted_phase.nil?
          raise ArgumentError, "completed evaluation requires output, score and boolean review_approved"
        end
        expected = self.class.accepted?(confidence: @confidence,
          confidence_threshold: @confidence_threshold, review_approved: @review_approved) ? "accepted" : "iteration_limit"
        raise ArgumentError, "termination_reason contradicts evaluation" unless @termination_reason == expected
      end
    end
  end
end
