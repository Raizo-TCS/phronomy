# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      module Scorer
        class ExactMatch < Base
          def initialize(case_sensitive: true)
            @case_sensitive = case_sensitive
          end

          def score(actual:, expected:, input: nil)
            actual_value = actual.to_s.strip
            expected_value = expected.to_s.strip
            unless @case_sensitive
              actual_value = actual_value.downcase
              expected_value = expected_value.downcase
            end
            (actual_value == expected_value) ? 1.0 : 0.0
          end
        end
      end
    end
  end
end
