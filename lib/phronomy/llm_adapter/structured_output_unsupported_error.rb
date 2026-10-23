# frozen_string_literal: true

module Phronomy
  module LLMAdapter
    # The selected native schema path cannot implement the requested contract.
    # @api public
    class StructuredOutputUnsupportedError < Phronomy::Error
      # @api public
      def initialize(message = "Native structured output is unsupported")
        super(message, code: "llm.structured_output_unsupported")
      end
    end
  end
end
