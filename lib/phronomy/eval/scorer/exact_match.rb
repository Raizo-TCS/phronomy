# frozen_string_literal: true

module Phronomy
  module Eval
    module Scorer
      # Scorer that returns 1.0 when the actual output exactly matches the
      # expected output (after stripping leading/trailing whitespace).
      # Comparison is case-sensitive by default.
      #
      # @example
      #   ExactMatch.new.score(actual: "Paris", expected: "Paris")  # => 1.0
      #   ExactMatch.new.score(actual: "paris", expected: "Paris")  # => 0.0
      class ExactMatch < Base
        # @param case_sensitive [Boolean] default true
        def initialize(case_sensitive: true)
          @case_sensitive = case_sensitive
        end

        # @return [Float] 1.0 on match, 0.0 otherwise
        def score(actual:, expected:, input: nil)
          a = actual.to_s.strip
          e = expected.to_s.strip
          a = a.downcase and e = e.downcase unless @case_sensitive
          (a == e) ? 1.0 : 0.0
        end
      end
    end
  end
end
