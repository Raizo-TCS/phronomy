# frozen_string_literal: true

module Phronomy
  # Runtime observability snapshot for the two concurrency boundaries:
  # EventLoop and the default OffloadPool. Observation never creates resources;
  # missing resources contribute zero values. Individual counters are sampled
  # independently, not as an atomic view of concurrent execution.
  module Metrics
    def self.snapshot
      runtime = Runtime.__default_if_initialized
      pool = runtime&.__offload_if_initialized
      event_loop = runtime&.__event_loop_if_initialized

      {
        offload_pool_active: pool&.active_count || 0,
        offload_pool_queue_length: pool&.queue_depth || 0,
        offload_pool_abandoned_active: pool&.abandoned_active_count || 0,
        offload_pool_abandoned_total: pool&.abandoned_count || 0,
        offload_pool_size: pool&.pool_size || 0,
        event_loop_queue_depth: event_loop&.queue_depth || 0,
        event_loop_queue_max_depth: event_loop&.max_queue_depth || 0,
        event_loop_lag_last_ms: ((event_loop&.last_lag_seconds || 0.0) * 1000).round(3),
        event_loop_lag_max_ms: ((event_loop&.max_lag_seconds || 0.0) * 1000).round(3),
        event_loop_lag_average_ms: ((event_loop&.average_lag_seconds || 0.0) * 1000).round(3)
      }
    end
  end
end
