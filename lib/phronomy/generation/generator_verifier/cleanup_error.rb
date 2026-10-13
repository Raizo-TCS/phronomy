# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    class CleanupError < Phronomy::Error
      attr_reader :pipeline, :failures, :result, :primary_error

      def initialize(pipeline:, failures:, result: nil, primary_error: nil, code: "generation.cleanup_failed")
        @pipeline, @result, @primary_error = pipeline, result, primary_error
        @failures = failures.map { |failure| failure.dup.freeze }.freeze
        super("Could not release #{failures.length} GeneratorVerifier Agent(s)", code: code)
      end
    end
  end
end
