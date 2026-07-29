# frozen_string_literal: true

module Phronomy
  module Agent
    # Centralises Tool execution routing based on execution_mode.
    # @api private
    module ToolExecutor
      WARNED_MODES = Set.new
      WARNED_MODES_MUTEX = Mutex.new
      private_constant :WARNED_MODES, :WARNED_MODES_MUTEX

      # Agent-owned execution boundary. Only a ToolInvocation that has consumed
      # authorization may enter this method.
      def self.call_invocation_async(
        tool_invocation:,
        cancellation_token: nil,
        config: {},
        runtime: Phronomy::Runtime.instance
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
          runtime: runtime
        )
      end

      # Low-level Tool API used by direct Tool#call_async callers. Agent execution
      # must use .call_invocation_async so authorization cannot be bypassed.
      def self.call_async(
        tool:,
        args:,
        cancellation_token: nil,
        config: {},
        runtime: Phronomy::Runtime.instance
      )
        ct = cancellation_token
        mode = tool.class.execution_mode

        if mode == :cpu_bound || mode == :external_process
          warn_key = [tool.class.name, mode]
          newly_warned = WARNED_MODES_MUTEX.synchronize { WARNED_MODES.add?(warn_key) }
          if newly_warned
            message = if mode == :cpu_bound
              "[Phronomy] Tool #{tool.class.name} declares execution_mode :cpu_bound, " \
                "which has no dedicated executor. Falling back to blocking_io " \
                "(BlockingAdapterPool). Use :blocking_io explicitly to suppress this warning."
            else
              "[Phronomy] Tool #{tool.class.name} declares execution_mode :external_process, " \
                "which has no dedicated process manager. Falling back to blocking_io " \
                "(BlockingAdapterPool)."
            end
            if Phronomy.configuration.logger
              Phronomy.configuration.logger.warn(message)
            else
              warn message
            end
          end
          mode = :blocking_io
        end

        pool = begin
          runtime&.blocking_io
        rescue
          nil
        end

        if mode == :cooperative || pool.nil?
          runtime.spawn(name: "tool-#{tool.class.name.to_s.split("::").last}") do
            tool.call(args, cancellation_token: ct)
          end
        else
          timeout = config[:tool_timeout]
          pool.submit(cancellation_token: ct, timeout: timeout) do
            tool.call(args, cancellation_token: ct)
          end
        end
      end
    end
  end
end
