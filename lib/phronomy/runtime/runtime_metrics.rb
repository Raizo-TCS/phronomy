# frozen_string_literal: true

module Phronomy
  class Runtime
    # Internal store for task-centric counters and latency samples.
    #
    # All access is mutex-protected.  The ring buffers for wait/run times are
    # bounded to {WINDOW} samples so that long-lived runtimes do not grow
    # unbounded.
    # @api private
    class RuntimeMetrics
      WINDOW = 1000
      private_constant :WINDOW

      def initialize
        @mutex = Mutex.new
        @active_by_type = Hash.new(0)
        @wait_ms = []
        @run_ms = []
        @cancelled = Hash.new(0)
        @failed = Hash.new(0)
        @starvation_count = 0
      end

      # Records that a new task of +type+ has been spawned.
      # @param type [Symbol]
      # @return [void]
      # @api private
      def record_start(type)
        @mutex.synchronize { @active_by_type[type] += 1 }
      end

      # Appends a wait-time sample (milliseconds from spawn to start).
      # @param wait_ms [Float]
      # @return [void]
      # @api private
      def record_wait(wait_ms)
        @mutex.synchronize do
          @wait_ms << wait_ms
          @wait_ms.shift if @wait_ms.size > WINDOW
        end
      end

      # Records completion of a task (decrements active count, appends run time).
      # @param type    [Symbol]
      # @param outcome [:completed, :cancelled, :failed]
      # @param run_start_ms [Integer] monotonic millisecond timestamp from task start
      # @return [void]
      # @api private
      def record_end(type, outcome, run_start_ms)
        run_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - run_start_ms
        @mutex.synchronize do
          @active_by_type[type] = [@active_by_type[type] - 1, 0].max
          @run_ms << run_ms
          @run_ms.shift if @run_ms.size > WINDOW
          case outcome
          when :cancelled then @cancelled[type] += 1
          when :failed then @failed[type] += 1
          end
        end
      end

      # Increments the CPU-starvation counter (task ran without yielding over
      # the configured +blocking_detect_threshold_ms+ threshold).
      # @return [void]
      # @api private
      def increment_starvation
        @mutex.synchronize { @starvation_count += 1 }
      end

      # Returns the current starvation counter value.
      # @return [Integer]
      # @api private
      def starvation_count
        @mutex.synchronize { @starvation_count }
      end

      # Returns the full task-centric metrics hash (see {Runtime#task_snapshot}).
      # @return [Hash{Symbol => Numeric}]
      # @api private
      def snapshot
        @mutex.synchronize do
          active = @active_by_type.dup
          wait = @wait_ms.dup
          run = @run_ms.dup
          cancelled = @cancelled.values.sum
          failed = @failed.values.sum
          starvation = @starvation_count
          {
            active_agent_tasks: active[:agent].to_i,
            active_tool_tasks: active[:tool].to_i,
            active_workflow_tasks: active[:workflow].to_i,
            active_rag_tasks: active[:rag].to_i,
            active_llm_tasks: active[:llm].to_i,
            task_wait_time_p50_ms: _percentile(wait, 50),
            task_wait_time_p95_ms: _percentile(wait, 95),
            task_run_time_p50_ms: _percentile(run, 50),
            task_run_time_p95_ms: _percentile(run, 95),
            cancelled_tasks: cancelled,
            failed_tasks: failed,
            non_yield_duration_max_ms: starvation
          }
        end
      end

      private

      def _percentile(samples, pct)
        return 0.0 if samples.empty?

        sorted = samples.sort
        idx = ((pct / 100.0) * (sorted.size - 1)).round
        sorted[idx].round(3)
      end
    end
  end
end
