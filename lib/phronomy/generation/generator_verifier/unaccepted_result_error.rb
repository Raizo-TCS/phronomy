# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    class UnacceptedResultError < Phronomy::Error
      attr_reader :result

      def initialize(result, code: "generation.result_unaccepted")
        @result = result
        super("Generation did not satisfy its evaluation conditions (#{result.termination_reason})", code: code)
      end
    end
  end
end
