# frozen_string_literal: true

module Phronomy
  module Guardrail
    # Guardrail applied to agent/chain output before it is returned to the caller.
    #
    # @example
    #   class NoSecretsGuardrail < Phronomy::Guardrail::OutputGuardrail
    #     def check(output)
    #       fail!("Response contains a secret key") if output.to_s.match?(/sk-[A-Za-z0-9]{32,}/)
    #     end
    #   end
    #
    #   agent = MyAgent.new
    #   agent.add_output_guardrail(NoSecretsGuardrail.new)
    class OutputGuardrail < Base
    end
  end
end
