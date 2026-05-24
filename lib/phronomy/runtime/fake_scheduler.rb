# frozen_string_literal: true

module Phronomy
  class Runtime
    # Synchronous scheduler for use in tests.
    #
    # Each spawned task is executed immediately on the calling thread using
    # {Task::ImmediateBackend}.  No new threads are created, so a
    # {Runtime} that uses +FakeScheduler+ does not increase the process
    # Thread count on {Runtime#spawn}.
    #
    # In addition to the basic synchronous execution, +FakeScheduler+ records
    # all task lifecycle events in {#event_log} and all spawned tasks in
    # {#tasks}.  This allows specs to assert event ordering and task state
    # without relying on wall-clock sleeps.
    #
    # === tick / tick_until
    #
    # Because +FakeScheduler+ uses {Task::ImmediateBackend}, every task runs
    # to completion before {Runtime#spawn} returns.  Consequently {#tick} is
    # semantically a no-op -- the "ready task" has already executed.  It is
    # provided so that test code written against the cooperative scheduler
    # interface compiles and documents intent (e.g. "advance by one step").
    #
    # === pending_timers
    #
    # If a {Phronomy::Testing::FakeClock} is injected via {#clock=}, its
    # pending callbacks are surfaced as +pending_timers+.
    #
    # @example
    #   runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
    #   task = runtime.spawn(name: "agent-test") { 42 }
    #   expect(task.await).to eq(42)
    #   expect(task.status).to eq(:completed)
    class FakeScheduler < Scheduler
      # @return [Array<Hash>] ordered list of task lifecycle events.
      #   Each entry is +{ type:, task_name:, at: }+ where +type+ is one of
      #   +:spawned+, +:started+, +:completed+, +:cancelled+, +:failed+ and
      #   +at+ is a Float monotonic timestamp (seconds).
      attr_reader :event_log

      # @return [Array<Hash>] all tasks spawned by this scheduler.
      #   Each entry is +{ task:, name:, status: }+.
      attr_reader :tasks

      # Optional {Phronomy::Testing::FakeClock} used to timestamp events and
      # surface pending timers.  When +nil+, a real monotonic clock is used.
      # @return [Phronomy::Testing::FakeClock, nil]
      attr_accessor :clock

      def initialize
        @event_log = []
        @tasks = []
        @clock = nil
        @mutex = Mutex.new
      end

      # Spawns +block+ as a {Task} backed by {Task::ImmediateBackend}.
      # The block executes synchronously before this method returns.
      # Lifecycle events are recorded in {#event_log}.
      #
      # @param name   [String, nil]
      # @param parent [Task, nil]
      # @return [Task]
      # @api private
      def spawn(name:, parent:, &block)
        _log_event(:spawned, name)
        task = Task.spawn(name: name, parent: parent, backend_class: Task::ImmediateBackend) do
          _log_event(:started, name)
          begin
            result = block.call
            _log_event(:completed, name)
            result
          rescue CancellationError
            _log_event(:cancelled, name)
            raise
          rescue => e
            _log_event(:failed, name)
            raise e
          end
        end
        @mutex.synchronize { @tasks << {task: task, name: name, status: task.status} }
        task
      end

      # Execute one ready task.
      #
      # Because {Task::ImmediateBackend} runs tasks synchronously inside
      # {#spawn}, all ready tasks have already executed by the time this
      # method is called.  This method is a no-op provided for API
      # compatibility with cooperative scheduler interfaces.
      #
      # @return [self]
      # @api private
      def tick
        self
      end

      # Run +block+ repeatedly until it returns truthy or +max_ticks+ is
      # reached.  Because tasks execute synchronously, the condition is
      # evaluated once; if it is already met this method returns immediately.
      #
      # @param max_ticks [Integer] safety bound (default: 1000)
      # @yield condition evaluated after each tick
      # @return [Boolean] +true+ if condition was satisfied
      # @api private
      def tick_until(max_ticks: 1000)
        max_ticks.times do
          return true if yield
          tick
        end
        yield ? true : false
      end

      # Returns a list of pending timer entries surfaced from the injected
      # {clock}.  Returns an empty array when no clock is set.
      #
      # @return [Array<Hash>] each entry: +{ fire_at:, description: }+
      # @api private
      def pending_timers
        return [] unless @clock

        @clock.pending_timer_entries
      end

      # Assert that the named tasks completed in the given order.
      # Raises +RSpec::Expectations::ExpectationNotMetError+ if order is wrong.
      # Intended for use inside RSpec examples.
      #
      # @param names [Array<String, nil>] task names in expected order
      # @return [void]
      # @api private
      def assert_order(*names)
        completed = @event_log.select { |e| e[:type] == :completed }.map { |e| e[:task_name] }
        indices = names.map { |n| completed.index(n) }
        unless indices.none?(&:nil?) && indices == indices.sort
          raise RSpec::Expectations::ExpectationNotMetError,
            "Expected tasks to complete in order #{names.inspect} " + "but completed order was #{completed.inspect}"
        end
      end

      # Assert that the named tasks reached +:cancelled+ state.
      #
      # @param names [Array<String, nil>] task names expected to be cancelled
      # @return [void]
      # @api private
      def assert_cancelled(*names)
        cancelled = @event_log.select { |e| e[:type] == :cancelled }.map { |e| e[:task_name] }
        missing = names.reject { |n| cancelled.include?(n) }
        return if missing.empty?

        raise RSpec::Expectations::ExpectationNotMetError,
          "Expected tasks #{missing.inspect} to be cancelled " + "but cancelled tasks were #{cancelled.inspect}"
      end

      private

      def _log_event(type, task_name)
        at = @clock ? @clock.now : Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex.synchronize { @event_log << {type: type, task_name: task_name, at: at} }
      end
    end
  end
end
