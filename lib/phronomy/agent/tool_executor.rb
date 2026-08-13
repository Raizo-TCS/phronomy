# frozen_string_literal: true

module Phronomy
  module Agent
    # Routes Tool work according to the Tool execution contract.
    #
    # :cooperative Tool calls execute inline and must return quickly. call_async
    # wraps their result in an already-settled Task and never consumes an
    # OffloadPool worker.
    #
    # :offloaded Tool calls route synchronous work through OffloadPool. Phronomy
    # does not distinguish whether the reason is blocking I/O, CPU-bound work, or
    # another long synchronous operation.
    module ToolExecutor
      def self.call_async(
        tool:,
        args:,
        cancellation_token: nil,
        config: {},
        runtime: nil,
        on_full: :raise
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
        when :offloaded
          runtime ||= Phronomy::Runtime.instance
          runtime.offload.submit(
            cancellation_token: cancellation_token,
            on_full: on_full
          ) do
            tool.call(args, cancellation_token: cancellation_token)
          end
        else
          raise Phronomy::ConfigurationError,
            "unknown Tool execution_mode: #{mode.inspect}"
        end
      end
    end
  end
end
