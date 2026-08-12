# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      EvalResult = Data.define(:eval_case, :actual, :score, :usage, :latency_ms, :error) do
        def initialize(eval_case:, actual:, score:, usage:, latency_ms:, error: nil)
          super
        end

        def pass? = score >= 1.0
        def scorer_error? = !error.nil?
      end
    end
  end
end
