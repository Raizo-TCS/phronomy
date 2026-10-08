# frozen_string_literal: true

module Phronomy
  module Tracing
    module Observation
      # Convenience wrapper that delegates to the global tracer.
      # Yields a span; the block must return [result, usage] where usage is a
      # Phronomy::LLMAdapter::TokenUsage or nil. Returns only the result value.
      #
      # When +trace_pii+ is disabled, both the input and the output (LLM response,
      # tool result) are replaced with the literal string "[REDACTED]" before being
      # forwarded to the tracing backend. The actual result is still returned to
      # the caller — only the copy sent to the tracer is redacted.
      #
      # @example
      #   trace("my_chain", input: input) { [invoke(input), nil] }
      # @api public
      def self.trace(name, input: nil, **meta, &block)
        traced_input = Settings.current.trace_pii ? input : "[REDACTED]"

        if Settings.current.trace_pii
          # PII recording is allowed: pass through unchanged.
          Settings.current.tracer.trace(name, input: traced_input, **meta, &block)
        else
          # Redact both input (above) and output before forwarding to the tracer.
          # Capture the real result so callers receive the unredacted value.
          real_result = nil
          Settings.current.tracer.trace(name, input: traced_input, **meta) do |span|
            real_result, usage = block.call(span)
            ["[REDACTED]", usage]
          end
          real_result
        end
      end
    end
  end
end
