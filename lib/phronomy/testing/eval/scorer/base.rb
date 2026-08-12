# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      module Scorer
        class Base
          def score(actual:, expected:, input: nil)
            raise NotImplementedError, "#{self.class}#score is not implemented"
          end
        end
      end
    end
  end
end
