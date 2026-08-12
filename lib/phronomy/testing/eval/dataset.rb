# frozen_string_literal: true

module Phronomy
  module Testing
    module Eval
      class Dataset
        include Enumerable

        def initialize(cases = [])
          @cases = cases.freeze
        end

        def self.from_array(pairs)
          new(pairs.map { |item| EvalCase.new(**item) })
        end

        def each(&block)
          @cases.each(&block)
        end

        def size
          @cases.size
        end
      end
    end
  end
end
