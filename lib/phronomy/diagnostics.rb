# frozen_string_literal: true

module Phronomy
  # Developer-facing diagnostics for EventLoop and offload execution boundaries.
  module Diagnostics
    def self.dump(out: $stderr)
      snap = Phronomy::Metrics.snapshot

      out.puts "[Phronomy::Diagnostics] Runtime state dump"
      out.puts "  OffloadPool:"
      out.puts "    pool_size       : #{snap[:offload_pool_size]}"
      out.puts "    active_count    : #{snap[:offload_pool_active]}"
      out.puts "    queue_depth     : #{snap[:offload_pool_queue_length]}"
      out.puts "    abandoned_total : #{snap[:offload_pool_abandoned_total]}"
      out.puts "  EventLoop:"
      out.puts "    last_lag_ms     : #{snap[:event_loop_lag_last_ms]}"
      out.puts "    max_lag_ms      : #{snap[:event_loop_lag_max_ms]}"
      out.puts "    average_lag_ms  : #{snap[:event_loop_lag_average_ms]}"
    end

    def self.snapshot
      Phronomy::Metrics.snapshot
    end

    def self.assert_not_in_event_loop!
      return unless Phronomy::Runtime.in_event_loop_context?

      raise Phronomy::EventLoopReentrancyError,
        "Blocking invoke called from inside an EventLoop action. Use invoke_async instead."
    end
  end
end
