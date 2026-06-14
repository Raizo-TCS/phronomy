# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Adds input and output guardrail support to an agent.
      #
      # Included in {Phronomy::Agent::Base}. Guardrails are run on the raw
      # input string before the LLM is called, and on the raw output string
      # before the result is returned to the caller.
      # @api private
      module Guardrailable
        # Attach a guardrail that validates input before every #invoke call.
        # The guardrail is included in the input filter chain and runs before
        # any filters registered via {#add_input_filter}.
        # @param guardrail [Phronomy::Guardrail::InputGuardrail]
        # @return [self]
        # @api public
        def add_input_guardrail(guardrail)
          @input_guardrails ||= []
          @input_guardrails << guardrail
          self
        end

        # Attach a guardrail that validates output before it is returned.
        # The guardrail is included in the output filter chain and runs before
        # any filters registered via {#add_output_filter}.
        # @param guardrail [Phronomy::Guardrail::OutputGuardrail]
        # @return [self]
        # @api public
        def add_output_guardrail(guardrail)
          @output_guardrails ||= []
          @output_guardrails << guardrail
          self
        end

        private

        # @deprecated Guardrails are now executed through run_input_filters!.
        #   Kept for internal compatibility; do not call directly.
        def run_input_guardrails!(input)
          (@input_guardrails || []).each { |g| g.run!(input) }
        end

        # @deprecated Guardrails are now executed through run_output_filters!.
        #   Kept for internal compatibility; do not call directly.
        def run_output_guardrails!(output)
          (@output_guardrails || []).each { |g| g.run!(output) }
        end
      end
    end
  end
end
