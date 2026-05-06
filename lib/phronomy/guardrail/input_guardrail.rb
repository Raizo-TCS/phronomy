# frozen_string_literal: true

module Phronomy
  module Guardrail
    # Guardrail applied to agent/chain input before it reaches the LLM.
    #
    # @example
    #   class NoCreditCardGuardrail < Phronomy::Guardrail::InputGuardrail
    #     def check(input)
    #       fail!("Credit card numbers are not allowed") if input.to_s.match?(/\d{4}[- ]\d{4}[- ]\d{4}[- ]\d{4}/)
    #     end
    #   end
    #
    #   agent = MyAgent.new
    #   agent.add_input_guardrail(NoCreditCardGuardrail.new)
    class InputGuardrail < Base
    end
  end
end
