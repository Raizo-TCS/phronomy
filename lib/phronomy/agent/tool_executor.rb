# frozen_string_literal: true

module Phronomy
  module Agent
    # Routes only genuinely blocking Tool work to BlockingAdapterPool.
    # Agent lifecycle coordination itself is owned by ToolInvocationSessionBuilder.
    module ToolExecutor
      def self.call_invocation_async(
        tool_invocation:,
        cancellation_token: nil,
        config: {},
        runtime: Phronomy::Runtime.instance,
        on_full: :raise
      )
        unless tool_invocation.dispatchable?
          raise Phronomy::ToolError,
            "ToolInvocation #{tool_invocation.id} is not authorized for dispatch"
        end

        call_async(
          tool: tool_invocation.tool,
          args: tool_invocation.arguments,
          cancellation_token: cancellation_token,
          config: config,
          runtime: runtime,
          on_full: on_full
        )
      end

      # Direct Tool#call_async remains asynchronous by using the one permitted
      # blocking-I/O worker boundary. Agent-owned :cooperative tools do not use
      # this method; they execute as short EventLoop actions.
      def self.call_async(
        tool:,
        args:,
        cancellation_token: nil,
        config: {},
        runtime: Phronomy::Runtime.instance,
        on_full: :wait
      )
        mode = tool.class.execution_mode
        case mode
        when :cpu_bound
          raise Phronomy::ConfigurationError,
            "Tool #{tool.class.name} declares :cpu_bound, but no CPU executor is configured"
        when :external_process
          raise Phronomy::ConfigurationError,
            "Tool #{tool.class.name} declares :external_process, but no process executor is configured"
        when :cooperative, :blocking_io
          # For direct async calls, a worker boundary is required to return immediately.
        else
          raise Phronomy::ConfigurationError,
            "unknown Tool execution_mode: #{mode.inspect}"
        end

        runtime.blocking_io.submit(
          cancellation_token: cancellation_token,
          on_full: on_full
        ) do
          tool.call(args, cancellation_token: cancellation_token)
        end
      end
    end
  end
end
