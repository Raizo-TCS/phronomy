# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      module Scorer
        class IncludesScorer < Base
          def initialize(case_sensitive: false)
            @case_sensitive = case_sensitive
          end

          def score(actual:, expected:, input: nil)
            actual_value = actual.to_s
            expected_value = expected.to_s
            unless @case_sensitive
              actual_value = actual_value.downcase
              expected_value = expected_value.downcase
            end
            actual_value.include?(expected_value) ? 1.0 : 0.0
          end
        end
      end
    end
  end
end
