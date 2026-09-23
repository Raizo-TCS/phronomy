# frozen_string_literal: true

module Phronomy
  module Agent
    # Builds invocation-independent Tool decorators from explicit Agent settings.
    # Authorization, execution and Orchestrator context remain with their owners.
    # @api private
    class ToolBinding
      def initialize(tool_class, alias_name:)
        @tool_class = if alias_name
          Class.new(tool_class) do
            tool_name alias_name
          end
        else
          tool_class
        end
      end

      def prepare(result_filters:)
        return @tool_class if result_filters.empty?

        effective_name = @tool_class.new.name
        custom_async_call =
          @tool_class.instance_method(:call_async).owner !=
          Phronomy::Agent::Context::Capability::Base
        filter_async_result = method(:filter_async_result)

        Class.new(@tool_class) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            result = super(args, **kwargs)
            result_filters.inject(result) { |val, filter|
              filter.call(val, tool_name: name, args: args)
            }
          end

          if custom_async_call
            define_method(:call_async) do |args, **kwargs|
              source = super(args, **kwargs)
              filter_async_result.call(source, name) do |value|
                result_filters.inject(value) { |val, filter|
                  filter.call(val, tool_name: name, args: args)
                }
              end
            end
          end
        end
      end

      private

      def filter_async_result(source, tool_name, &filter_result)
        filtered = Phronomy::Concurrency::PhysicalCompletionTask.deferred(
          name: "tool-filter-#{tool_name}"
        )
        source_has_physical_signal = source.respond_to?(:on_physical_complete)
        source.on_physical_complete { filtered.mark_physical_complete! } if
          source_has_physical_signal
        source.on_complete do |value, error|
          if error
            propagate_failure(filtered, source, error, source_has_physical_signal)
          else
            complete_filtered_result(filtered, source_has_physical_signal) do
              filter_result.call(value)
            end
          end
        end
        filtered
      end

      def propagate_failure(filtered, source, error, source_has_physical_signal)
        filtered.mark_physical_complete! unless source_has_physical_signal
        if source.respond_to?(:status) && source.status == :cancelled
          filtered.cancel!(error)
        else
          filtered.fail(error)
        end
      end

      def complete_filtered_result(filtered, source_has_physical_signal)
        result = yield
        filtered.mark_physical_complete! unless source_has_physical_signal
        filtered.complete(result)
      rescue => filter_error
        filtered.mark_physical_complete! unless source_has_physical_signal
        filtered.fail(filter_error)
      end
    end
  end
end
