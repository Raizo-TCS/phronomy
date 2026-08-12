# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      class Comparison
        ComparisonPair = Data.define(:eval_case, :result_a, :result_b)

        def initialize(scorer: Scorer::ExactMatch.new)
          @scorer = scorer
        end

        def compare(dataset, callable_a, callable_b)
          results_a = Runner.new(scorer: @scorer).run(dataset, callable_a)
          results_b = Runner.new(scorer: @scorer).run(dataset, callable_b)
          results_a.zip(results_b).map do |a, b|
            ComparisonPair.new(eval_case: a.eval_case, result_a: a, result_b: b)
          end
        end
      end
    end
  end
end
