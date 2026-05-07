# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Tracing
    # Abstract tracer.
    #
    # To integrate a tracing backend (OpenTelemetry, Langfuse, etc.),
    # subclass this and override #start_span and #finish_span.
    # Then assign your tracer in the Phronomy configuration:
    #
    #   Phronomy.configure do |c|
    #     c.tracer = MyTracer.new
    #   end
    #
    # The tracer is then automatically used by Chain and Agent components
    # via the #trace helper.
    class Base
      # Wraps a block in a span. Yields the span to the block.
      # Calls #finish_span with the output on success or with the error on failure.
      #
      # @param name [String] span / trace name
      # @param input [Object] the input being processed
      # @param meta [Hash] additional metadata attached to the span
      # @yield [span] the active span object
      # @return [Object] the block's return value
      def trace(name, input: nil, **meta)
        span = start_span(name, input: input, **meta)
        result, usage = yield span
        finish_span(span, output: result, usage: usage)
        result
      rescue => e
        finish_span(span, error: e)
        raise
      end

      # Start a new span. Must return an object that will be passed to #finish_span.
      #
      # @param name [String]
      # @param attributes [Hash]
      # @return [Object] an opaque span handle
      def start_span(name, **attributes)
        raise NotImplementedError, "#{self.class}#start_span is not implemented"
      end

      # Finish a span after execution completes.
      #
      # @param span [Object] the span returned by #start_span
      # @param output [Object, nil] successful output value
      # @param usage [Phronomy::TokenUsage, nil] token usage for this span
      # @param error [Exception, nil] exception if the block raised
      def finish_span(span, output: nil, usage: nil, error: nil)
        raise NotImplementedError, "#{self.class}#finish_span is not implemented"
      end
    end
  end
end
