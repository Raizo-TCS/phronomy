# frozen_string_literal: true

module Phronomy
  # Runtime observability snapshot for the two concurrency boundaries:
  # EventLoop and OffloadPool.
  module Metrics
    def self.snapshot
      runtime = Runtime.instance
      pool = runtime.offload
      event_loop = runtime.event_loop

      {
        offload_pool_active: pool.active_count,
        offload_pool_queue_length: pool.queue_depth,
        offload_pool_abandoned_total: pool.abandoned_count,
        offload_pool_size: pool.pool_size,
        event_loop_queue_depth: event_loop.queue_depth,
        event_loop_queue_max_depth: event_loop.max_queue_depth,
        event_loop_lag_last_ms: (event_loop.last_lag_seconds * 1000).round(3),
        event_loop_lag_max_ms: (event_loop.max_lag_seconds * 1000).round(3),
        event_loop_lag_average_ms: (event_loop.average_lag_seconds * 1000).round(3)
      }
    end
  end
end
