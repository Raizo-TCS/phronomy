# frozen_string_literal: true

module Phronomy
  # Task-centric observability snapshot (Issue #276).
  #
  # Collects live metrics from the shared Runtime components
  # (BlockingAdapterPool and EventLoop) and returns them as a plain
  # Hash so they can be forwarded to any monitoring backend
  # (Prometheus, OpenTelemetry, StatsD, etc.).
  #
  # All metrics are read at the moment {.snapshot} is called; no
  # persistent state is held here.
  #
  # @example Exporting to a metrics endpoint
  #   data = Phronomy::Metrics.snapshot
  #   # => { blocking_pool_active: 2, blocking_pool_queue_length: 5, ... }
  module Metrics
    # Returns a Hash of current observability metrics.
    #
    # Keys and their sources:
    #
    # | Key | Source | Units |
    # |-----|--------|-------|
    # | `blocking_pool_active`         | BlockingAdapterPool#active_count   | tasks |
    # | `blocking_pool_queue_length`   | BlockingAdapterPool#queue_depth    | tasks |
    # | `blocking_pool_abandoned_total`| BlockingAdapterPool#abandoned_count| tasks |
    # | `blocking_pool_size`           | BlockingAdapterPool#pool_size      | workers |
    # | `event_loop_lag_last_ms`       | EventLoop#last_lag_seconds * 1000  | ms |
    # | `event_loop_lag_max_ms`        | EventLoop#max_lag_seconds * 1000   | ms |
    # | `event_loop_lag_average_ms`    | EventLoop#average_lag_seconds * 1000| ms |
    #
    # @return [Hash{Symbol => Numeric}]
    # @api public
    def self.snapshot
      pool = Runtime.instance.blocking_io
      el   = EventLoop.instance

      {
        blocking_pool_active:          pool.active_count,
        blocking_pool_queue_length:    pool.queue_depth,
        blocking_pool_abandoned_total: pool.abandoned_count,
        blocking_pool_size:            pool.pool_size,
        event_loop_lag_last_ms:        (el.last_lag_seconds * 1000).round(3),
        event_loop_lag_max_ms:         (el.max_lag_seconds * 1000).round(3),
        event_loop_lag_average_ms:     (el.average_lag_seconds * 1000).round(3)
      }
    end
  end
end
