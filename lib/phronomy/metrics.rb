# frozen_string_literal: true

module Phronomy
  # Task-centric observability snapshot (Issue #276, extended in #307).
  #
  # Collects live metrics from the shared Runtime components
  # (BlockingAdapterPool, EventLoop, and Runtime task registry) and returns
  # them as a plain Hash so they can be forwarded to any monitoring backend
  # (Prometheus, OpenTelemetry, StatsD, etc.).
  #
  # All metrics are read at the moment {.snapshot} is called; no
  # persistent state is held here.
  #
  # @example Exporting to a metrics endpoint
  #   data = Phronomy::Metrics.snapshot
  #   # => { blocking_pool_active: 2, active_agent_tasks: 1, ... }
  module Metrics
    # Returns a Hash of current observability metrics.
    #
    # @return [Hash{Symbol => Numeric}]
    # @api public
    def self.snapshot
      runtime = Runtime.instance
      pool = runtime.blocking_io
      el = runtime.event_loop
      task_snap = runtime.task_snapshot

      {
        blocking_pool_active: pool.active_count,
        blocking_pool_queue_length: pool.queue_depth,
        blocking_pool_abandoned_total: pool.abandoned_count,
        blocking_pool_size: pool.pool_size,
        event_loop_queue_depth: el.queue_depth,
        event_loop_queue_max_depth: el.max_queue_depth,
        event_loop_lag_last_ms: (el.last_lag_seconds * 1000).round(3),
        event_loop_lag_max_ms: (el.max_lag_seconds * 1000).round(3),
        event_loop_lag_average_ms: (el.average_lag_seconds * 1000).round(3)
      }.merge(task_snap)
    end
  end
end
