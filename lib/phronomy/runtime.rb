# frozen_string_literal: true

module Phronomy
  # Central factory for concurrent primitives.
  #
  # +Runtime+ is the single place that knows how to create {Task}s,
  # {TaskGroup}s, and (in future) schedule work on a cooperative scheduler.
  # Agent / workflow / tool code asks the Runtime for a group or task rather
  # than calling +Thread.new+ directly.  This keeps all threading concern in
  # one location and makes it possible to substitute a test double or a
  # Fiber-based scheduler without modifying call sites.
  #
  # A default shared instance is available via {.instance}.  Individual agent
  # invocations may carry a custom Runtime in their {InvocationContext} to
  # apply per-invocation limits (e.g. reduced parallelism, injected fakes).
  #
  # @example Using the shared Runtime
  #   group = Phronomy::Runtime.instance.task_group(limit: 4)
  #   tools.each { |t| group.spawn { t.call } }
  #   results = group.await_all
  class Runtime
    # Returns the process-wide default Runtime.
    # @return [Runtime]
    def self.instance
      @instance ||= new
    end

    # Replaces the process-wide default Runtime.  Useful in tests.
    # @param runtime [Runtime]
    # @return [Runtime]
    def self.instance=(runtime)
      @instance = runtime
    end

    # Creates a new {TaskGroup} with an optional concurrency cap.
    #
    # @param limit [Integer, Float::INFINITY] max simultaneous tasks
    # @return [TaskGroup]
    def task_group(limit: Float::INFINITY)
      TaskGroup.new(limit: limit)
    end

    # Spawns a single background {Task}.
    #
    # @param name [String, nil] optional label for debugging
    # @yield block to execute concurrently
    # @return [Task]
    def spawn(name: nil, &block)
      Task.spawn(name: name, &block)
    end
  end
end
