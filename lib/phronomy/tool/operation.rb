# frozen_string_literal: true

module Phronomy
  module Tool
    # Tool operation protocol: execution modes, custom async dispatch, and
    # completion-handle validation. Agent approval/progress are separate owners.
    # @api public
    module Operation
      # Starts one Tool operation. The submitter implements Execution submission
      # for the default offloaded path; custom call_async keeps its public protocol
      # and owns its execution mechanism. Neither receives a concrete Runtime.
      # @return [#on_complete] the original completion handle
      # @api public
      def self.call_async(tool:, args:, cancellation_token: nil, config: {},
        submitter: Phronomy::Execution, on_full: :raise)
        unless %i[cooperative offloaded].include?(tool.class.execution_mode)
          raise Phronomy::ConfigurationError,
            "unknown Tool execution_mode: #{tool.class.execution_mode.inspect}"
        end
        operation = if custom_async?(tool.method(:call_async))
          tool.call_async(args, cancellation_token: cancellation_token, config: config)
        else
          ToolExecutor.call_async(tool: tool, args: args,
            cancellation_token: cancellation_token, config: config,
            submitter: submitter, on_full: on_full)
        end
        unless operation.respond_to?(:on_complete)
          raise Phronomy::ToolError,
            "Tool #{tool.class.name}#call_async must return a completion handle"
        end
        operation
      end

      # Decorates synchronous Tool results and custom async completions. A custom
      # async operation is mapped through Execution's physical-completion-aware
      # operation contract. The caller owns the meaning of the transformation.
      # @return [Class<Phronomy::Tool::Base>] a derived Tool class
      # @api public
      def self.with_result_transform(tool_class, &transform)
        raise ArgumentError, "a result transformation is required" unless transform
        effective_name = tool_class.new.name
        custom_async_call = custom_async?(tool_class.instance_method(:call_async))
        Class.new(tool_class) do
          tool_name effective_name
          define_method(:call) do |args, **kwargs|
            result = super(args, **kwargs)
            transform.call(result, name, args)
          end
          if custom_async_call
            define_method(:call_async) do |args, **kwargs|
              source = super(args, **kwargs)
              Phronomy::AsyncOperation.map(source, name: "tool-filter-#{name}") do |value|
                transform.call(value, name, args)
              end
            end
          end
        end
      end

      def self.custom_async?(method)
        method.owner != Base
      end
      private_class_method :custom_async?
    end
  end
end
