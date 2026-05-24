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
    # This makes it straightforward to write deterministic unit tests for
    # code that uses Runtime without introducing thread timing dependencies.
    #
    # @example
    #   runtime = Phronomy::Runtime.new(scheduler: Phronomy::Runtime::FakeScheduler.new)
    #   task = runtime.spawn { 42 }
    #   expect(task.await).to eq(42)
    #   expect(task.status).to eq(:completed)
    class FakeScheduler < Scheduler
      # Spawns +block+ as a {Task} backed by {Task::ImmediateBackend}.
      # The block executes synchronously before this method returns.
      #
      # @param name   [String, nil]
      # @param parent [Task, nil]
      # @return [Task]
      def spawn(name:, parent:, &block)
        Task.spawn(name: name, parent: parent, backend_class: Task::ImmediateBackend, &block)
      end
    end
  end
end
