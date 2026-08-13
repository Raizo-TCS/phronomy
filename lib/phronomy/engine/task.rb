# frozen_string_literal: true

module Phronomy
  # A thread-free asynchronous completion handle.
  #
  # Task no longer executes work. Execution belongs to EventLoop/FSMSession or
  # OffloadPool. Task only represents completion, failure, cancellation,
  # callbacks and a blocking wait for external callers.
  class Task
    STATES = %i[pending completed failed cancelled].freeze
    TERMINAL_STATES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATES

    def self.deferred(name: nil, parent: nil)
      new(name: name, parent: parent)
    end

    attr_reader :name, :parent

    def initialize(name: nil, parent: nil)
      @name = name
      @parent = parent
      @status = :pending
      @value = nil
      @error = nil
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @children = []
      @on_complete_callbacks = []
      parent&.register_child(self)
    end

    def status
      @mutex.synchronize { @status }
    end

    def done?
      @mutex.synchronize { TERMINAL_STATES.include?(@status) }
    end

    def alive?
      !done?
    end

    # Blocks the calling thread until settlement. EventLoop is never allowed to
    # wait for a Task; it must continue through explicit events instead.
    def wait_result(timeout: nil)
      if Phronomy::Runtime.in_event_loop_context? && !done?
        raise Phronomy::EventLoopReentrancyError,
          "Task#wait_result cannot block the EventLoop thread; continue via an event"
      end

      deadline = timeout && monotonic_now + timeout.to_f
      value, error = @mutex.synchronize do
        until TERMINAL_STATES.include?(@status)
          if deadline
            remaining = deadline - monotonic_now
            if remaining <= 0
              raise Phronomy::TimeoutError,
                "timed out waiting for Task #{@name || "(unnamed)"}"
            end
            @cond.wait(@mutex, remaining)
          else
            @cond.wait(@mutex)
          end
        end
        [@value, @error]
      end

      raise error if error
      value
    end

    # Compatibility wait that does not re-raise the task error.
    # Returns self when settled, nil on timeout.
    def join(limit = nil)
      if Phronomy::Runtime.in_event_loop_context? && !done?
        raise Phronomy::EventLoopReentrancyError,
          "Task#join cannot block the EventLoop thread; continue via an event"
      end

      deadline = limit && monotonic_now + limit.to_f
      @mutex.synchronize do
        until TERMINAL_STATES.include?(@status)
          if deadline
            remaining = deadline - monotonic_now
            return nil if remaining <= 0
            @cond.wait(@mutex, remaining)
          else
            @cond.wait(@mutex)
          end
        end
      end
      self
    end

    # Registers an independent completion notification.
    #
    # A callback failure is logged and does not suppress delivery to other
    # completion callbacks or change the Task's already-settled result.
    def on_complete(&callback)
      raise ArgumentError, "on_complete requires a block" unless callback

      fire_args = nil
      @mutex.synchronize do
        if TERMINAL_STATES.include?(@status)
          fire_args = [@value, @error]
        else
          @on_complete_callbacks << callback
        end
      end
      deliver_completion_callback(callback, *fire_args) if fire_args
      self
    end

    def complete(value = nil)
      settle!(:completed, value: value)
    end

    def fail(error)
      raise ArgumentError, "error is required" unless error
      settle!(:failed, error: error)
    end

    def cancel!(error = Phronomy::CancellationError.new("Task cancelled"))
      changed = settle!(:cancelled, error: error)
      if changed
        children = @mutex.synchronize { @children.dup }
        children.each(&:cancel!)
      end
      self
    end

    def map(&block)
      raise ArgumentError, "map requires a block" unless block

      mapped = self.class.deferred(name: "#{@name}-mapped", parent: @parent)
      on_complete do |value, error|
        if error
          mapped.fail(error)
          next
        end

        begin
          mapped.complete(block.call(value))
        rescue => mapped_error
          mapped.fail(mapped_error)
        end
      end
      mapped
    end

    protected

    def register_child(child)
      @mutex.synchronize { @children << child }
    end

    private

    def settle!(new_status, value: nil, error: nil)
      callbacks = nil
      changed = @mutex.synchronize do
        next false if TERMINAL_STATES.include?(@status)

        @status = new_status
        @value = value
        @error = error
        callbacks = @on_complete_callbacks.dup
        @on_complete_callbacks.clear
        @cond.broadcast
        true
      end
      if changed
        callbacks.each do |callback|
          deliver_completion_callback(callback, value, error)
        end
      end
      changed
    end

    def deliver_completion_callback(callback, value, error)
      callback.call(value, error)
    rescue => callback_error
      Phronomy.configuration.logger&.error do
        "[Task] on_complete callback raised #{callback_error.class}: #{callback_error.message}"
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
