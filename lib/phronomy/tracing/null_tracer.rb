# frozen_string_literal: true

module Phronomy
  module Tracing
    # No-op tracer used as the default. All calls succeed silently.
    #
    # Swap this with a real tracer (OpenTelemetry, Langfuse, etc.) via:
    #
    #   Phronomy.configure { |c| c.tracer = MyRealTracer.new }
    class NullTracer < Base
      # Internal value object for span handles returned by #start_span.
      # Uses Struct (not OpenStruct) so that unknown attribute access raises NoMethodError.
      SpanStruct = Struct.new(:name)
      private_constant :SpanStruct

      # Returns a minimal span object with the given name.
      def start_span(name, **) = SpanStruct.new(name)

      # Does nothing.
      def finish_span(span, **) = nil
    end
  end
end
