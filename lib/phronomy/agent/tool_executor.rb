# frozen_string_literal: true

module Phronomy
  module Agent
    # Centralises tool execution routing based on {Tool::Base.execution_mode}.
    #
    # This is the single place in the framework that decides *how* a tool call is
    # dispatched:
    #
    # - +:cooperative+       — dispatched via +Runtime#spawn+ through the configured
    #                          scheduler. Under the +:fiber+ backend this avoids an
    #                          extra OS thread; under the +:thread+ backend it is
    #                          backed by +ThreadScheduler+ (one thread per task).
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
    # @note Non-goals
    #   ToolExecutor deliberately does NOT provide:
    #   - A CPU-bound process pool. CPU-intensive tool work must be handled at the
    #     application layer (e.g., fork, Sidekiq, separate OS processes). The
    #     framework will not add a +ProcessPoolExecutor+ equivalent.
    #   - An external process manager. Spawning or supervising subprocesses is
    #     out of scope for this module.
    #   - Additional core execution routes beyond scheduler-backed cooperative
    #     execution and BlockingAdapterPool-backed blocking I/O isolation.
    #     The +:cpu_bound+ and +:external_process+ modes are accepted for
    #     compatibility but both fall back to +:blocking_io+ routing with a
    #     one-time warning. If a genuinely new core execution route is needed,
    #     a new ADR is required.
    #   These non-goals follow from the cooperative-first, non-preemptive
    #   concurrency model (ADR-010): framework components must not assume the
    #   caller's concurrency model, and CPU/process management belongs to the
    #   application layer.
    #
    # @api private
    module ToolExecutor
    # Tracks tool classes that have already emitted an execution_mode warning so
    # that the same warning is only logged once per process lifetime.
    WARNED_MODES = Set.new
    WARNED_MODES_MUTEX = Mutex.new
    private_constant :WARNED_MODES, :WARNED_MODES_MUTEX

    # Dispatches a single tool call asynchronously according to its
    # +execution_mode+ and returns an awaitable.
    #
    # @param tool               [Phronomy::Tool::Base] the tool instance to invoke
    # @param args               [Hash]                 argument hash to pass to {Tool::Base#call}
    # @param cancellation_token [Phronomy::Concurrency::CancellationToken, nil]
    # @param runtime            [Phronomy::Runtime]    runtime to use for spawning
    #                           (defaults to {Runtime.instance}; injectable for tests)
    # @return [#await] a {Phronomy::Task} or {BlockingAdapterPool::PendingOperation}
    # @api private
    def self.call_async(tool:, args:, cancellation_token: nil, runtime: Phronomy::Runtime.instance)
      ct = cancellation_token
      mode = tool.class.execution_mode

      # Warn and normalise unsupported modes to :blocking_io.
      # Each (tool class, mode) pair emits the warning at most once per process
      # lifetime to avoid log flooding in high-throughput scenarios.
      if mode == :cpu_bound || mode == :external_process
        warn_key = [tool.class.name, mode]
        newly_warned = WARNED_MODES_MUTEX.synchronize { WARNED_MODES.add?(warn_key) }
        if newly_warned
          msg = if mode == :cpu_bound
            "[Phronomy] Tool #{tool.class.name} declares execution_mode :cpu_bound, " \
            "which has no dedicated executor. " \
            "Falling back to blocking_io (BlockingAdapterPool). " \
            "Use :blocking_io explicitly to suppress this warning."
          else
            "[Phronomy] Tool #{tool.class.name} declares execution_mode :external_process, " \
            "which has no dedicated process manager. " \
            "Falling back to blocking_io (BlockingAdapterPool)."
          end
          if Phronomy.configuration.logger
            Phronomy.configuration.logger.warn(msg)
          else
            warn msg
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
        # Submit directly to pool — no wrapping Task thread required.
        pool.submit(cancellation_token: ct) { tool.call(args, cancellation_token: ct) }
      end
    end
  end
  end
end
