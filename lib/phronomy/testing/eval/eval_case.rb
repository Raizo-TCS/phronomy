# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      EvalCase = Data.define(:input, :expected, :metadata) do
        def initialize(input:, expected:, metadata: {})
          super
        end
      end
    end
  end
end
