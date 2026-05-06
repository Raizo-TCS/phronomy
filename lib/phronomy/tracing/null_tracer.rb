# frozen_string_literal: true

require "ostruct"

module Phronomy
  module Tracing
    # No-op tracer used as the default. All calls succeed silently.
    #
    # Swap this with a real tracer (OpenTelemetry, Langfuse, etc.) via:
    #
    #   Phronomy.configure { |c| c.tracer = MyRealTracer.new }
    class NullTracer < Base
      # Returns a minimal span object with the given name.
      def start_span(name, **) = OpenStruct.new(name: name)

      # Does nothing.
      def finish_span(span, **) = nil
    end
  end
end
