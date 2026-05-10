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
    # @example
    #   trace("my_chain", input: input) { [invoke(input), nil] }
    def trace(name, input: nil, **meta, &block)
      # Redact user input from spans when trace_pii is disabled to prevent
      # accidental PII transmission to external tracing backends.
      traced_input = Phronomy.configuration.trace_pii ? input : "[REDACTED]"
      Phronomy.configuration.tracer.trace(name, input: traced_input, **meta, &block)
    end
  end
end
