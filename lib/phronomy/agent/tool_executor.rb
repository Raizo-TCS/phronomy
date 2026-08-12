# frozen_string_literal: true

module Phronomy
  module Agent
    # Routes Tool work according to the Tool execution contract.
    #
    # :cooperative Tool calls execute inline and must return quickly. call_async
    # wraps their result in an already-settled Task and never consumes a
    # BlockingAdapterPool worker.
    #
    # :blocking_io Tool calls are the only core Tool path routed through
    # BlockingAdapterPool.
    module ToolExecutor
      def self.call_async(
        tool:,
        args:,
        cancellation_token: nil,
        config: {},
        runtime: nil,
        on_full: :wait
      )
        mode = tool.class.execution_mode

        case mode
        when :cooperative
          task = Phronomy::Task.deferred(name: "tool-#{tool.name}")
          begin
            task.complete(
              tool.call(args, cancellation_token: cancellation_token)
            )
          rescue => error
            task.fail(error)
          end
          task
        when :blocking_io
          runtime ||= Phronomy::Runtime.instance
          runtime.blocking_io.submit(
            cancellation_token: cancellation_token,
            on_full: on_full
          ) do
            tool.call(args, cancellation_token: cancellation_token)
          end
        when :cpu_bound
          raise Phronomy::ConfigurationError,
            "Tool #{tool.class.name} declares :cpu_bound, but no CPU executor is configured"
        when :external_process
          raise Phronomy::ConfigurationError,
            "Tool #{tool.class.name} declares :external_process, but no process executor is configured"
        else
          raise Phronomy::ConfigurationError,
            "unknown Tool execution_mode: #{mode.inspect}"
        end
      end
    end
  end
end
