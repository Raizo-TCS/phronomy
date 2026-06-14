# frozen_string_literal: true

module Phronomy
  module Guardrail
    # Abstract base class for all guardrails.
    #
    # Subclasses override #check to validate input or output.
    # Call #fail! inside #check to reject with a reason.
    #
    # @example
    #   class NoPIIGuardrail < Phronomy::Guardrail::InputGuardrail
    #     def check(input)
    #       fail!("PII detected") if input.to_s.match?(/\d{3}-\d{2}-\d{4}/)
    #     end
    #   end
    class Base
      # Validate the value. Subclasses must implement this method.
      # @param value [Object] the input or output being checked
      # @raise [Phronomy::GuardrailError] if the guardrail rejects the value
      # @api public
      def check(value)
        raise NotImplementedError, "#{self.class}#check is not implemented"
      end

      # Run the check and return the value unchanged when it passes.
      # Satisfies the {Phronomy::Filter::Base} interface so that guardrails can
      # participate in the unified filter chain.
      #
      # @param value [Object]
      # @return [Object] the original value when the check passes
      # @raise [Phronomy::GuardrailError] if the guardrail rejects the value
      # @api public
      def call(value, **_context)
        check(value)
        value
      end

      # Run the check, raising GuardrailError on failure.
      # @param value [Object]
      # @return [Object] the original value (unchanged) when the check passes
      # @api public
      def run!(value)
        check(value)
        value
      end

      protected

      # Call inside #check to reject the value.
      # @param reason [String] human-readable rejection reason
      # @raise [Phronomy::GuardrailError]
      # @api public
      def fail!(reason)
        raise Phronomy::GuardrailError.new(reason, guardrail: self)
      end
    end
  end
end
