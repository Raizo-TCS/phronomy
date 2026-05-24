# frozen_string_literal: true

module Phronomy
  module Tracing
    # OpenTelemetry tracer adapter.
    #
    # Requires the +opentelemetry-api+ gem (or +opentelemetry-sdk+ for testing).
    # The caller is responsible for configuring the OpenTelemetry SDK before
    # using this tracer — phronomy does not configure an exporter or propagator.
    #
    # @example Configure globally
    #   require "opentelemetry-sdk"
    #   OpenTelemetry::SDK.configure { |c| c.use_all }
    #
    #   Phronomy.configure do |c|
    #     c.tracer = Phronomy::Tracing::OpenTelemetryTracer.new
    #   end
    class OpenTelemetryTracer < Base
      # @param tracer_name [String] name passed to the OTel TracerProvider
      # @api public
      def initialize(tracer_name: "phronomy")
        require "opentelemetry"
        @otel_tracer = OpenTelemetry.tracer_provider.tracer(tracer_name, Phronomy::VERSION)
      end

      # Starts an OTel span.
      # Input and extra metadata are stored as span attributes prefixed with
      # +phronomy.+.
      #
      # @return [OpenTelemetry::Trace::Span]
      # @api public
      def start_span(name, input: nil, **attributes)
        attrs = {}
        attrs["phronomy.input"] = input.to_s if input
        attributes.each { |k, v| attrs["phronomy.#{k}"] = v.to_s }
        @otel_tracer.start_span(name, attributes: attrs)
      end

      # Finishes the OTel span, recording output, token usage, or error.
      def finish_span(span, output: nil, usage: nil, error: nil)
        if error
          span.record_exception(error)
          span.status = OpenTelemetry::Trace::Status.error(error.message)
        else
          span.set_attribute("phronomy.output", output.to_s) if output
          if usage
            span.set_attribute("llm.usage.input_tokens", usage.input)
            span.set_attribute("llm.usage.output_tokens", usage.output)
            total = (usage.input || 0) + (usage.output || 0)
            span.set_attribute("llm.usage.total_tokens", total)
          end
        end
        span.finish
      end

      # Overrides Base#trace to use OTel +in_span+, which pushes the span onto
      # the OTel Context stack while the block runs.  Nested +trace+ calls
      # automatically inherit the current span as their parent, establishing the
      # correct parent/child hierarchy in the trace tree.
      #
      # @param name [String] span name
      # @param input [Object, nil] input to record as a span attribute
      # @param meta [Hash] additional metadata (e.g. task_id, user_id)
      # @yield [span] the active OTel span
      # @return [Object] the block's return value
      def trace(name, input: nil, **meta)
        attrs = {}
        attrs["phronomy.input"] = input.to_s if input
        meta.each { |k, v| attrs["phronomy.#{k}"] = v.to_s unless v.nil? }

        result = nil
        @otel_tracer.in_span(name, attributes: attrs) do |span|
          result, usage = yield span
          span.set_attribute("phronomy.output", result.to_s) if result
          if usage
            span.set_attribute("llm.usage.input_tokens", usage.input)
            span.set_attribute("llm.usage.output_tokens", usage.output)
            total = (usage.input || 0) + (usage.output || 0)
            span.set_attribute("llm.usage.total_tokens", total)
          end
        rescue => e
          span.record_exception(e)
          span.status = OpenTelemetry::Trace::Status.error(e.message)
          raise
        end
        result
      end
    end
  end
end
