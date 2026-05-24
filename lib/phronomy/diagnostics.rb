# frozen_string_literal: true

module Phronomy
  # Developer-facing diagnostics for blocking operation detection (Issue #279).
  #
  # Provides debug dump utilities that can be called from an IRB / Rails console
  # or in test helpers to inspect the current state of the Runtime.
  #
  # @example Enable diagnostics and print a dump
  #   Phronomy.configure { |c| c.scheduler_debug = true }
  #   Phronomy::Diagnostics.dump
  module Diagnostics
    # Prints a formatted summary of the current Runtime state to +$stderr+
    # (or the supplied IO).
    #
    # Includes:
    # - BlockingAdapterPool: active workers, queue depth, abandoned count
    # - EventLoop: last / max / average lag in milliseconds
    #
    # @param out [IO] output destination (default: $stderr)
    # @return [void]
    # @api public
    def self.dump(out: $stderr)
      snap = Phronomy::Metrics.snapshot

      out.puts "[Phronomy::Diagnostics] Runtime state dump"
      out.puts "  BlockingAdapterPool:"
      out.puts "    pool_size       : #{snap[:blocking_pool_size]}"
      out.puts "    active_count    : #{snap[:blocking_pool_active]}"
      out.puts "    queue_depth     : #{snap[:blocking_pool_queue_length]}"
      out.puts "    abandoned_total : #{snap[:blocking_pool_abandoned_total]}"
      out.puts "  EventLoop:"
      out.puts "    last_lag_ms     : #{snap[:event_loop_lag_last_ms]}"
      out.puts "    max_lag_ms      : #{snap[:event_loop_lag_max_ms]}"
      out.puts "    average_lag_ms  : #{snap[:event_loop_lag_average_ms]}"
    end

    # Returns the diagnostics state as a plain Hash (useful for JSON export).
    #
    # @return [Hash]
    # @api public
    def self.snapshot
      Phronomy::Metrics.snapshot
    end

    # Raises an error if +invoke+ (blocking) is called from inside an EventLoop
    # action, preventing accidental scheduler stalls.
    #
    # Called by Agent::Base#invoke and Workflow#invoke before executing.
    #
    # @raise [Phronomy::SchedulerReentrancyError] when called from EventLoop thread
    # @return [void]
    # @api private
    def self.assert_not_in_event_loop!
      return unless Thread.current[:phronomy_event_loop_thread]

      raise Phronomy::SchedulerReentrancyError,
        "Blocking invoke called from inside an EventLoop action. " \
        "Use invoke_async instead."
    end
  end
end
