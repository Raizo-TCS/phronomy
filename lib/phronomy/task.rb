# frozen_string_literal: true

require_relative "task/backend"
require_relative "task/thread_backend"
require_relative "task/immediate_backend"

module Phronomy
  # A single unit of concurrent work.
  #
  # Decouples task semantics from the underlying execution primitive via a
  # pluggable {Backend}.  The default backend is {ThreadBackend}; a cooperative
  # or test-double backend can be substituted via {.default_backend_class=} or
  # by passing +backend_class:+ to {.spawn}.
  #
  # @example Basic usage
  #   task = Phronomy::Task.spawn { expensive_io() }
  #   result = task.await   # blocks until done, re-raises errors
  #
  # @example Cancel a running task
  #   task = Phronomy::Task.spawn { loop { Phronomy::Task.checkpoint! } }
  #   task.cancel!
  #
  # @example Task tree — cancel parent cancels children
  #   parent = Phronomy::Task.spawn { sleep 10 }
  #   child  = Phronomy::Task.spawn(parent: parent) { sleep 10 }
  #   parent.cancel!   # child is also cancelled
  class Task
    # Valid task lifecycle states.
    STATES = %i[pending running completed failed cancelled].freeze

    # Returns the process-wide default backend class.
    # Defaults to {ThreadBackend}.
    # Override in tests or to enable a cooperative scheduler backend.
    # @return [Class<Backend>]
    def self.default_backend_class
      @default_backend_class || ThreadBackend
    end

    # Sets the process-wide default backend class.
    # @param klass [Class<Backend>]
    def self.default_backend_class=(klass)
      @default_backend_class = klass
    end

    # Returns the {Task} currently executing on this thread, or +nil+.
    # Returns +nil+ when called from outside a task-managed execution context.
    # @return [Task, nil]
    def self.current
      Thread.current[:phronomy_current_task]
    end

    # Cooperative cancellation checkpoint.
    #
    # Raises {CancellationError} if the current task's status is +:cancelled+.
    # On {ThreadBackend}, cancellation is delivered via +Thread#raise+ so this
    # is a no-op in practice; on future cooperative backends this will be the
    # primary cancellation mechanism.
    #
    # Safe to call from outside a task context (no-op when no current task).
    # @return [void]
    # @raise [CancellationError] if the current task has been cancelled
    def self.checkpoint!
      ct = current
      return unless ct

      raise CancellationError, "Task cancelled" if ct.status == :cancelled
    end

    # Spawns a new task executing +block+ concurrently.
    #
    # @param name          [String, nil]    optional human-readable label
    # @param parent        [Task, nil]      parent task; cancelling the parent
    #   also cancels this task (default: currently running task)
    # @param backend_class [Class<Backend>] backend to use
    # @yieldreturn [Object] the task result
    # @return [Task]
    def self.spawn(name: nil, parent: current, backend_class: default_backend_class, &block)
      new(name: name, parent: parent, backend_class: backend_class, &block)
    end

    # @return [String, nil] optional human-readable label
    attr_reader :name

    # @return [Task, nil] parent task in the task tree, if any
    attr_reader :parent

    # @param name          [String, nil]
    # @param parent        [Task, nil]
    # @param backend_class [Class<Backend>]
    # @api private use {.spawn} instead
    def initialize(name: nil, parent: nil, backend_class: self.class.default_backend_class, &block)
      @name = name
      @parent = parent
      @status = :pending
      @mutex = Mutex.new
      @children = []
      parent&.register_child(self)
      @backend = backend_class.new(task: self, &block)
    end

    # Returns the current lifecycle state.
    # @return [Symbol] one of {STATES}
    def status
      @mutex.synchronize { @status }
    end

    # Blocks until the task completes and returns its value.
    # Re-raises any exception raised inside the block.
    #
    # @return [Object] the result produced by the block
    # @raise [Exception] if the block raised an error
    def await
      @backend.await
    end

    # Returns +true+ once the task has finished (success, error, or cancellation).
    # @return [Boolean]
    def done?
      %i[completed failed cancelled].include?(status)
    end

    # Requests cancellation.  Propagates to all registered child tasks.
    # Sets status to :cancelled immediately so that even tasks that have not
    # started executing yet are correctly marked as cancelled after join.
    # @return [self]
    def cancel!
      transition!(:cancelled)
      @backend.cancel!
      children = @mutex.synchronize { @children.dup }
      children.each(&:cancel!)
      self
    end

    # Joins the underlying execution context, optionally with a timeout.
    # Returns +nil+ when the timeout expires before completion.
    #
    # @param limit [Numeric, nil] seconds to wait; nil waits indefinitely
    # @return [Object, nil]
    def join(limit = nil)
      @backend.join(limit)
    end

    # Returns +true+ while the task's block is still executing.
    # @return [Boolean]
    def alive?
      @backend.alive?
    end

    # Updates the task lifecycle state.
    # Called by backends during execution transitions.
    # Terminal states (completed/failed/cancelled) are never overwritten.
    # @param new_status [Symbol]
    # @api private
    def transition!(new_status)
      @mutex.synchronize do
        # Check @status directly (not via #done?) to avoid re-entering the mutex.
        return if %i[completed failed cancelled].include?(@status)

        @status = new_status
      end
    end

    # Registers +child+ as a child task for cancellation propagation.
    # Called automatically during child task initialization.
    # @param child [Task]
    # @api private
    def register_child(child)
      @mutex.synchronize { @children << child }
    end
  end
end
