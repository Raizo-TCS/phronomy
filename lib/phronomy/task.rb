# frozen_string_literal: true

require_relative "task/backend"
require_relative "task/thread_backend"
require_relative "task/immediate_backend"
require_relative "task/fiber_backend"
require_relative "task/mapped_backend"

module Phronomy
  # A single unit of concurrent work.
  #
  # Decouples task semantics from the underlying execution primitive via a
  # pluggable {Backend}.  The default backend is {ThreadBackend}; a cooperative
  # or test-double backend can be substituted via {.default_backend_class=} or
  # by passing +backend_class:+ to {.spawn}.
  #
  # +Task.spawn+ is an **internal API** used by schedulers and the framework
  # itself.  Application code and framework components should use
  # +Runtime.instance.spawn+ instead, which routes through the configured
  # scheduler and respects the concurrency model.
  #
  # @example Basic usage (framework/test code only — prefer Runtime.instance.spawn in app code)
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
    # @api private
    def self.default_backend_class
      @default_backend_class || ThreadBackend
    end

    # Sets the process-wide default backend class.
    # @param klass [Class<Backend>]
    # @api private
    def self.default_backend_class=(klass)
      @default_backend_class = klass
    end

    # Returns the {Task} currently executing on this thread, or +nil+.
    # Returns +nil+ when called from outside a task-managed execution context.
    # @return [Task, nil]
    # @api private
    def self.current
      Thread.current[:phronomy_current_task]
    end

    # Returns the monotonic clock value (ms) when the current task last recorded
    # a yield (or when the task started), or +nil+ when not inside a task context.
    # Used by {Runtime#yield} for CPU-bound detection without placing
    # +Thread.current+ in files outside the allowlist.
    # @return [Integer, nil]
    # @api private
    def self.current_cpu_slice_start_ms
      Thread.current[:phronomy_task_cpu_slice_start_ms]
    end

    # Resets the CPU slice start clock for the current task to +now+.
    # Call this immediately after the cooperative yield has been performed so
    # that the next yield correctly measures only the time since the last yield.
    # @api private
    def self.record_yield!
      Thread.current[:phronomy_task_cpu_slice_start_ms] =
        Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
    end

    # Returns and increments a per-thread yield-if-needed counter.
    # Used by {Runtime#yield_if_needed} so that the counter is thread-local
    # without putting +Thread.current+ in runtime.rb (which is outside the
    # Thread.current allowlist).
    # @return [Integer] the new counter value
    # @api private
    def self.increment_yield_counter!
      count = (Thread.current[:phronomy_yield_if_needed_counter] || 0) + 1
      Thread.current[:phronomy_yield_if_needed_counter] = count
      count
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
    # @api private
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
    # @api private
    def self.spawn(name: nil, parent: current, backend_class: default_backend_class, &block)
      new(name: name, parent: parent, backend_class: backend_class, &block)
    end

    # @return [String, nil] optional human-readable label
    attr_reader :name

    # @return [Task, nil] parent task in the task tree, if any
    attr_reader :parent

    # @return [Backend] the execution backend for this task
    # @api private
    attr_reader :backend

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
      @on_complete_callbacks = []
      @completed_value = nil
      @completed_error = nil
      parent&.register_child(self)
      @backend = backend_class.new(task: self, &block)
    end

    # Returns the current lifecycle state.
    # @return [Symbol] one of {STATES}
    # @api private
    def status
      @mutex.synchronize { @status }
    end

    # Blocks until the task completes and returns its value.
    # Re-raises any exception raised inside the block.
    #
    # @return [Object] the result produced by the block
    # @raise [Exception] if the block raised an error
    # @api private
    def await
      @backend.await
    end

    # Registers a callback to be invoked when the task reaches a terminal state
    # (+:completed+, +:failed+, or +:cancelled+).
    #
    # The callback receives two arguments: +value+ (the task's return value,
    # or +nil+) and +error+ (the exception, or +nil+).  These are provided
    # directly so the callback does not need to call +task.await+, which would
    # risk a self-join error when the callback runs inside the task's own thread.
    #
    # If the task is already done when this method is called, the callback is
    # invoked immediately (synchronously, on the calling thread).
    #
    # @yield [value, error] called when the task finishes
    # @return [self]
    # @api private
    def on_complete(&callback)
      fire_now = false
      fire_args = nil
      @mutex.synchronize do
        # Check @status directly to avoid re-entering the mutex (done? calls
        # status, which also takes @mutex).
        if %i[completed failed cancelled].include?(@status)
          fire_now = true
          fire_args = [@completed_value, @completed_error]
        else
          @on_complete_callbacks << callback
        end
      end
      callback.call(*fire_args) if fire_now
      self
    end

    # Returns a new {Task} whose completed value is the result of applying
    # +block+ to this task's completed value.
    #
    # If this task fails or is cancelled, the mapped task also fails/is
    # cancelled with the same error.  The block is never called in error cases.
    #
    # The primary use-case is transforming an agent result into a
    # {WorkflowContext} so that a Workflow entry action can return a Task
    # whose value is picked up by {FSMSession} via the existing
    # +:action_completed+ path:
    #
    # @example Returning agent output into a Workflow state field
    #   entry :translate, ->(ctx) {
    #     TranslationAgent.new.invoke_async(ctx.query).map do |result|
    #       ctx.merge(answer: result[:output])   # returns WorkflowContext
    #     end
    #   }
    #
    # @yield  [value] the completed value of this task
    # @yieldreturn [Object] the value for the mapped task
    # @return [Task] a new task that completes when this task does
    # @api public
    def map(&block)
      # MappedBackend drives the task lifecycle entirely via on_complete;
      # it never spawns a thread of its own.
      mapped = self.class.spawn(
        name: "#{@name}-mapped",
        parent: @parent,
        backend_class: MappedBackend
      ) {}

      on_complete do |value, error|
        mapped_value = nil
        mapped_error = error
        unless error
          begin
            mapped_value = block.call(value)
          rescue => e
            mapped_error = e
          end
        end
        if mapped_error
          mapped.transition!(:failed, error: mapped_error)
        else
          mapped.transition!(:completed, value: mapped_value)
        end
        # Unblock mapped.await / mapped.join after the terminal transition.
        mapped.backend.unblock(mapped_value, mapped_error)
      end
      mapped
    end

    # Returns +true+ once the task has finished (success, error, or cancellation).
    # @return [Boolean]
    # @api private
    def done?
      %i[completed failed cancelled].include?(status)
    end

    # Requests cancellation.  Propagates to all registered child tasks.
    # Sets status to :cancelled immediately so that even tasks that have not
    # started executing yet are correctly marked as cancelled after join.
    # Passes a CancellationError to on_complete callbacks so callers do not
    # need to call await to discover the error.
    # @return [self]
    # @api private
    def cancel!
      transition!(:cancelled, error: CancellationError.new("Task cancelled"))
      # @backend may be nil if cancel! is called while ImmediateBackend is still
      # initializing (the block runs synchronously inside .new, so register_child
      # fires before @backend is assigned).  Safe-navigate to avoid NoMethodError.
      @backend&.cancel!
      children = @mutex.synchronize { @children.dup }
      children.each(&:cancel!)
      self
    end

    # Joins the underlying execution context, optionally with a timeout.
    # Returns +nil+ when the timeout expires before completion.
    #
    # @param limit [Numeric, nil] seconds to wait; nil waits indefinitely
    # @return [Object, nil]
    # @api private
    def join(limit = nil)
      @backend.join(limit)
    end

    # Returns +true+ while the task's block is still executing.
    # @return [Boolean]
    # @api private
    def alive?
      @backend.alive?
    end

    # Updates the task lifecycle state.
    # Called by backends during execution transitions.
    # Terminal states (completed/failed/cancelled) are never overwritten.
    # When a terminal state is reached, fires on_complete callbacks (outside
    # the mutex) passing the result value and error directly.
    #
    # @param new_status [Symbol]
    # @param value      [Object, nil]    task return value (terminal states only)
    # @param error      [Exception, nil] exception raised by the block, if any
    # @api private
    def transition!(new_status, value: nil, error: nil)
      callbacks = nil
      @mutex.synchronize do
        # Check @status directly (not via #done?) to avoid re-entering the mutex.
        return if %i[completed failed cancelled].include?(@status)

        @status = new_status
        if %i[completed failed cancelled].include?(new_status)
          @completed_value = value
          @completed_error = error
          callbacks = @on_complete_callbacks.dup
          @on_complete_callbacks.clear
        end
      end
      callbacks&.each { |cb| cb.call(value, error) }
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
