# frozen_string_literal: true

module Phronomy
  # Base interface included by all Chain components.
  # Provides invoke / stream / batch and the pipeline composition operators >> / |.
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

    # Pipeline composition: self >> other
    def >>(other)
      Phronomy::Chain::Sequential.new([self, other])
    end

    # Pipeline composition: self | other (LCEL-style alias)
    alias_method :|, :>>

    # Convenience wrapper that delegates to the global tracer.
    # Yields a span; returns the block's return value.
    #
    # @example
    #   trace("my_chain", input: input) { invoke(input) }
    def trace(name, input: nil, **meta, &block)
      Phronomy.configuration.tracer.trace(name, input: input, **meta, &block)
    end
  end
end
