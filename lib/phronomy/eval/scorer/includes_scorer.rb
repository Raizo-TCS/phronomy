# frozen_string_literal: true

module Phronomy
  module Eval
    module Scorer
      # Scorer that returns 1.0 when the actual output contains the expected
      # substring (case-insensitive by default).
      #
      # Useful for open-ended outputs where the exact wording may vary but a
      # key term or phrase must be present.
      #
      # @example
      #   IncludesScorer.new.score(actual: "The answer is 42.", expected: "42")  # => 1.0
      class IncludesScorer < Base
        # @param case_sensitive [Boolean] default false
        # @api public
        def initialize(case_sensitive: false)
          @case_sensitive = case_sensitive
        end

        # @return [Float] 1.0 if actual contains expected, 0.0 otherwise
        # @api public
        def score(actual:, expected:, input: nil)
          a = actual.to_s
          e = expected.to_s
          a = a.downcase and e = e.downcase unless @case_sensitive
          a.include?(e) ? 1.0 : 0.0
        end
      end
    end
  end
end
