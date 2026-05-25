# frozen_string_literal: true

module Phronomy
  # Centralises tool execution routing based on {Tool::Base.execution_mode}.
  #
  # This is the single place in the framework that decides *how* a tool call is
  # dispatched:
  #
  # - +:cooperative+       — runs via +Runtime#spawn+ on the cooperative scheduler
  #                          (no extra OS thread).
  # - +:blocking_io+       — submitted to +BlockingAdapterPool+ when the runtime
  #                          provides a pool; falls back to +Runtime#spawn+ otherwise.
  # - +:cpu_bound+         — emits a deprecation-style warning then falls back to
  #                          +:blocking_io+ routing (no process pool available yet).
  # - +:external_process+  — falls back to +:blocking_io+ routing (no process
  #                          manager available yet).
  #
  # All paths return an object that responds to +#await+ (+Phronomy::Task+ or
  # +BlockingAdapterPool::PendingOperation+), so callers can collect results
  # uniformly.
  #
  # @api private
  module ToolExecutor
    # Dispatches a single tool call asynchronously according to its
    # +execution_mode+ and returns an awaitable.
    #
    # @param tool               [Phronomy::Tool::Base] the tool instance to invoke
    # @param args               [Hash]                 argument hash to pass to {Tool::Base#call}
    # @param cancellation_token [Phronomy::CancellationToken, nil]
    # @param runtime            [Phronomy::Runtime]    runtime to use for spawning
    #                           (defaults to {Runtime.instance}; injectable for tests)
    # @return [#await] a {Phronomy::Task} or {BlockingAdapterPool::PendingOperation}
    # @api private
    def self.call_async(tool:, args:, cancellation_token: nil, runtime: Phronomy::Runtime.instance)
      ct = cancellation_token
      mode = tool.class.execution_mode

      # Warn and normalise unsupported modes to :blocking_io.
      if mode == :cpu_bound || mode == :external_process
        msg = "[Phronomy] ToolExecutor: execution_mode :#{mode} is not yet supported " \
              "(no process pool available). Falling back to :blocking_io routing. " \
              "Tool: #{tool.class.name}"
        if Phronomy.configuration.logger
          Phronomy.configuration.logger.warn(msg)
        else
          warn msg
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
        # Submit directly to pool — no wrapping Task thread required.
        pool.submit(cancellation_token: ct) { tool.call(args, cancellation_token: ct) }
      end
    end
  end
end
