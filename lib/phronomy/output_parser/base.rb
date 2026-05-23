# frozen_string_literal: true

module Phronomy
  module OutputParser
    # Base class for all output parsers.
    # Can be embedded in a Chain as a Runnable.
    class Base
      include Phronomy::Runnable

      # @param input [String, #to_s] text to parse
      # @return [Object] parsed result
      # @api public
      def invoke(input, config: {})
        parse(input.is_a?(String) ? input : input.to_s)
      end

      # Implement in subclasses.
      def parse(text)
        raise NotImplementedError, "#{self.class}#parse is not implemented"
      end
    end
  end
end
