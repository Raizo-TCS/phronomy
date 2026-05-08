# frozen_string_literal: true

module Phronomy
  module Eval
    module Scorer
      # Abstract base class for all scorers.
      # Subclasses must implement {#score}.
      class Base
        # Scores an actual output against the expected output.
        #
        # @param actual   [String] the callable's output
        # @param expected [String] the ground-truth value from the EvalCase
        # @param input    [String, nil] the original input (used by LLM scorers)
        # @return [Float] a value in [0.0, 1.0]
        def score(actual:, expected:, input: nil)
          raise NotImplementedError, "#{self.class}#score is not implemented"
        end
      end
    end
  end
end
