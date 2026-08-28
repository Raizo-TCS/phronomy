# frozen_string_literal: true

module Phronomy
  module Tracing
    # Framework-private automatic instrumentation for the small D02-F03
    # logical-operation coverage set.
    #
    # This helper deliberately does not define trace-context propagation,
    # durable span state, or backend-native parent/child semantics.
    # @api private
    module Automatic
      REDACTED = "[REDACTED]"
      SENSITIVE_METADATA_KEYS = %i[user_id session_id].freeze

      Handle = Data.define(:name, :tracer, :span, :trace_pii)
      private_constant :Handle

      module_function

      def start(name, input: nil, **metadata)
        trace_pii = false
        configuration = Phronomy.configuration
        trace_pii = !!configuration.trace_pii
        tracer = configuration.tracer
        span = tracer.start_span(
          name,
          input: traced_payload(input, trace_pii: trace_pii),
          **safe_metadata(metadata, trace_pii: trace_pii)
        )
        Handle.new(
          name: name.to_s.freeze,
          tracer: tracer,
          span: span,
          trace_pii: trace_pii
        )
      rescue => error
        report_failure(:start, name, error, include_message: trace_pii)
        nil
      end

      def finish(handle, output: nil, usage: nil, error: nil)
        return nil unless handle

        attributes = {
          output: traced_payload(output, trace_pii: handle.trace_pii),
          usage: usage,
          error: traced_error(error, trace_pii: handle.trace_pii)
        }.freeze

        if Phronomy::Runtime.in_event_loop_context?
          submit_finish(handle, attributes)
        else
          finish_now(handle, attributes)
        end
        nil
      rescue => trace_error
        report_failure(
          :finish,
          handle&.name || "unknown",
          trace_error,
          include_message: handle ? handle.trace_pii : false
        )
        nil
      end

      def observe_task(task, name, input: nil, **metadata)
        handle = start(name, input: input, **metadata)
        task.on_complete do |value, error|
          finish(
            handle,
            output: value,
            usage: task_usage(value),
            error: error
          )
        end
        task
      end

      def trace(name, input: nil, **metadata)
        handle = start(name, input: input, **metadata)
        result = yield
        finish(handle, output: result, usage: task_usage(result))
        result
      rescue => operation_error
        finish(handle, error: operation_error) if defined?(handle)
        raise
      end

      def traced_payload(value, trace_pii:)
        return value if trace_pii
        return nil if value.nil?

        REDACTED
      end
      private_class_method :traced_payload

      def safe_metadata(metadata, trace_pii:)
        metadata.each_with_object({}) do |(key, value), safe|
          next if value.nil?

          normalized_key = key.respond_to?(:to_sym) ? key.to_sym : key
          next if !trace_pii && SENSITIVE_METADATA_KEYS.include?(normalized_key)

          safe[key] = value
        end
      end
      private_class_method :safe_metadata

      def traced_error(error, trace_pii:)
        return nil unless error
        return error if trace_pii

        redacted = error.exception(REDACTED)
        redacted.set_backtrace([])
        redacted
      rescue
        fallback = StandardError.new(REDACTED)
        fallback.set_backtrace([])
        fallback
      end
      private_class_method :traced_error

      def task_usage(value)
        return nil unless value.is_a?(Hash)

        value[:usage] || value["usage"]
      end
      private_class_method :task_usage

      def submit_finish(handle, attributes)
        Phronomy::Runtime.instance.offload.submit(on_full: :raise) do
          finish_now(handle, attributes)
        end
        nil
      rescue => error
        report_failure(
          :finish,
          handle.name,
          error,
          include_message: handle.trace_pii
        )
        nil
      end
      private_class_method :submit_finish

      def finish_now(handle, attributes)
        handle.tracer.finish_span(handle.span, **attributes)
        nil
      rescue => error
        report_failure(
          :finish,
          handle.name,
          error,
          include_message: handle.trace_pii
        )
        nil
      end
      private_class_method :finish_now

      def report_failure(stage, name, error, include_message:)
        detail = include_message ? ": #{error.message}" : ""
        message =
          "[Phronomy] automatic tracing #{stage} failed for " \
          "#{name}: #{error.class}#{detail}"
        logger = Phronomy.configuration.logger
        logger ? logger.warn(message) : Kernel.warn(message)
        nil
      rescue
        nil
      end
      private_class_method :report_failure
    end
  end
end
