# frozen_string_literal: true

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
    # The configured tracer instance may be shared by independent Phronomy
    # operations. Phronomy does not serialize calls to that instance; #trace,
    # #start_span, and #finish_span may therefore be entered concurrently.
    # Custom tracer implementations must not assume exclusive single-operation use
    # and must protect mutable shared state they own.
    #
    # This contract does not guarantee a particular OS thread, EventLoop,
    # OffloadPool worker, or async-context affinity. Framework-owned automatic
    # instrumentation uses this same start_span / finish_span SPI for a small
    # set of logical operations. Phronomy guarantees portable semantic
    # correlation metadata, not one backend-native parent/child span tree.
    class Base
      # Wraps a block in a span. Yields the span to the block.
      # Calls #finish_span with the output on success or with the error on failure.
      #
      # @param name [String] span / trace name
      # @param input [Object] the input being processed
      # @param meta [Hash] additional metadata attached to the span
      # @yield [span] the active span object
      # @return [Object] the block's return value
      # @api public
      def trace(name, input: nil, **meta)
        Base.trace_with(self, name, attributes: {input: input, **meta}) { |span| yield span }
      end

      # Use the public start/finish SPI, including duck-typed tracers.
      # Start failures do not finish; finish is attempted once after execution.
      # A secondary finish/reporting failure cannot replace the block's error.
      # Set record_output: false for metadata-only operations.
      # @api public
      def self.trace_with(tracer, name, record_output: true, attributes: {})
        span = tracer.start_span(name, **attributes)
        begin
          result, usage = yield span
        rescue => primary
          begin
            tracer.finish_span(span, error: primary)
          rescue => secondary
            report_secondary(secondary)
          end
          raise
        end
        if record_output
          tracer.finish_span(span, output: result, usage: usage)
        else
          tracer.finish_span(span)
        end
        result
      end

      def self.report_secondary(error)
        Phronomy::RuntimeSettings.current.logger&.warn(
          "[Phronomy::Tracing] secondary finish failure: #{error.class}: #{error.message}"
        )
      rescue
        # Diagnostics are best effort; preserve the primary business failure.
        nil
      end
      private_class_method :report_secondary

      # Start a new span. Must return an object that will be passed to #finish_span.
      #
      # @param name [String]
      # @param attributes [Hash]
      # @return [Object] an opaque span handle
      # @api public
      def start_span(name, **attributes)
        raise NotImplementedError, "#{self.class}#start_span is not implemented"
      end

      # Finish a span after execution completes.
      #
      # @param span [Object] the span returned by #start_span
      # @param output [Object, nil] successful output value
      # @param usage [Hash{Symbol => Integer, nil}, nil] observed token counts;
      #   :input, :output, :cached, :cache_creation. The caller projects its domain value.
      # @param error [Exception, nil] exception if the block raised
      # @api public
      def finish_span(span, output: nil, usage: nil, error: nil)
        raise NotImplementedError, "#{self.class}#finish_span is not implemented"
      end
    end
  end
end
