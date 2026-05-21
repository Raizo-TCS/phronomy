# frozen_string_literal: true

module Phronomy
  # Base interface for executable graph components.
  # Provides invoke / stream / batch.
  module Runnable
    # Synchronous execution. Must be overridden in subclasses.
    def invoke(input, config: {})
      raise NotImplementedError, "#{self.class}#invoke is not implemented"
    end

    # Streaming execution. Default yields the invoke result as a single chunk.
    def stream(input, config: {}, &block)
      result = invoke(input, config: config)
      yield result if block
      result
    end

    # Batch execution. Default calls invoke sequentially.
    def batch(inputs, config: {})
      inputs.map { |input| invoke(input, config: config) }
    end

    # Convenience wrapper that delegates to the global tracer.
    # Yields a span; the block must return [result, usage] where usage is a
    # Phronomy::TokenUsage or nil. Returns only the result value.
    #
    # When +trace_pii+ is disabled, both the input and the output (LLM response,
    # tool result) are replaced with the literal string "[REDACTED]" before being
    # forwarded to the tracing backend. The actual result is still returned to
    # the caller — only the copy sent to the tracer is redacted.
    #
    # @example
    #   trace("my_chain", input: input) { [invoke(input), nil] }
    def trace(name, input: nil, **meta, &block)
      traced_input = Phronomy.configuration.trace_pii ? input : "[REDACTED]"

      if Phronomy.configuration.trace_pii
        # PII recording is allowed: pass through unchanged.
        Phronomy.configuration.tracer.trace(name, input: traced_input, **meta, &block)
      else
        # Redact both input (above) and output before forwarding to the tracer.
        # Capture the real result so callers receive the unredacted value.
        real_result = nil
        Phronomy.configuration.tracer.trace(name, input: traced_input, **meta) do |span|
          real_result, usage = block.call(span)
          ["[REDACTED]", usage]
        end
        real_result
      end
    end
  end
end
