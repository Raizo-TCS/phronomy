# frozen_string_literal: true

require_relative "concurrency/worker_input_restricted"

module Phronomy
  # A thread-free asynchronous completion handle.
  #
  # TaskResult does not execute work. Execution belongs to EventLoop/FSMSession or
  # OffloadPool. TaskResult represents completion, failure, cancellation, callbacks,
  # and a blocking wait for callers outside EventLoop.
  #
  # Framework components own TaskResult settlement. Application code should observe a
  # TaskResult through {#wait_result}, {#on_complete}, {#map}, and state readers rather
  # than calling {#complete}, {#fail}, or {#cancel!}. Operation-wide cancellation
  # is supplied through the CancellationToken accepted by the API that created
  # the TaskResult.
  class TaskResult
    include Phronomy::Concurrency::WorkerInputRestricted

    STATES = %i[pending completed failed cancelled].freeze
    TERMINAL_STATES = %i[completed failed cancelled].freeze
    private_constant :TERMINAL_STATES

    # A shallow immutable input-position record. Application values are retained
    # by reference; they are neither copied nor frozen by this record.
    # @api public
    class Outcome < Struct.new(:index, :status, :value, :error)
      def initialize(**fields)
        super
        freeze
      end
    end

    # Observe already-created results without taking ownership of their work.
    # Invalid inputs are rejected before any completion subscription is added.
    # @param results [Array<TaskResult>]
    # @return [TaskResult<Array<Outcome>>]
    # @raise [TypeError] for a non-Array list or non-TaskResult element
    # @api public
    def self.all_settled(results)
      raise TypeError, "results must be an Array" unless results.is_a?(Array)

      inputs = results.dup
      inputs.each_with_index do |result, index|
        unless result.is_a?(Phronomy::TaskResult)
          raise TypeError, "results[#{index}] must be a Phronomy::TaskResult"
        end
      end
      combined = Phronomy::TaskResult.deferred(name: "all-settled")
      collector = Concurrency::ResultCollector.new(inputs.length) do |_, outcomes|
        combined.complete(outcomes)
      end
      inputs.each_with_index { |result, index| collector.watch(index, result) }
      collector.finish(:completed)
      combined
    end

    # Creates an unsettled completion handle for framework-owned execution.
    # @api private
    def self.deferred(name: nil, parent: nil)
      new(name: name, parent: parent)
    end

    # Public factories for already-settled values. No execution is started.
    # Always create a base TaskResult: there is no physical worker to supervise.
    # @param value [Object] already available result
    # @param name [String, nil] optional diagnostic name
    # @return [Phronomy::TaskResult] a completed base TaskResult
    # @api public
    def self.completed(value = nil, name: nil)
      Phronomy::TaskResult.deferred(name: name).tap { |task| task.complete(value) }
    end

    # Represents an already known failure without raising the stored error.
    # Observation through wait_result raises it; on_complete receives it.
    # @param error [Exception] original failure object
    # @param name [String, nil] optional diagnostic name
    # @return [Phronomy::TaskResult] a failed base TaskResult
    # @raise [ArgumentError] if error is not an Exception
    # @api public
    def self.failed(error, name: nil)
      raise ArgumentError, "error must be an Exception" unless error.is_a?(Exception)

      Phronomy::TaskResult.deferred(name: name).tap { |task| task.fail(error) }
    end

    attr_reader :name, :parent

    # @api private
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

    # @return [Symbol] :pending, :completed, :failed, or :cancelled
    # @api public
    def status
      @mutex.synchronize { @status }
    end

    # @return [Boolean] whether the TaskResult has reached a terminal state
    # @api public
    def done?
      @mutex.synchronize { TERMINAL_STATES.include?(@status) }
    end

    # @return [Boolean] whether the TaskResult has not yet reached a terminal state
    # @api public
    def alive?
      !done?
    end

    # Blocks the calling thread until settlement.
    #
    # EventLoop is never allowed to wait for a TaskResult; framework continuation must
    # proceed through explicit events. The optional timeout is waiter-local: it
    # does not settle or cancel the TaskResult.
    #
    # @param timeout [Numeric, nil] maximum seconds this caller will block
    # @return [Object] the completed value
    # @raise [Phronomy::TimeoutError] when the waiter-local timeout expires
    # @raise [Exception] the error that settled the TaskResult
    # @api public
    def wait_result(timeout: nil)
      if Phronomy::Runtime.in_event_loop_context? && !done?
        raise Phronomy::EventLoopReentrancyError,
          "TaskResult#wait_result cannot block the EventLoop thread; continue via an event"
      end

      deadline = timeout && monotonic_now + timeout.to_f
      value, error = @mutex.synchronize do
        until TERMINAL_STATES.include?(@status)
          if deadline
            remaining = deadline - monotonic_now
            if remaining <= 0
              raise Phronomy::TimeoutError,
                "timed out waiting for TaskResult #{@name || "(unnamed)"}"
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

    # Compatibility wait that does not re-raise the TaskResult error.
    # Returns self when settled, nil on timeout.
    # @api private
    def join(limit = nil)
      if Phronomy::Runtime.in_event_loop_context? && !done?
        raise Phronomy::EventLoopReentrancyError,
          "TaskResult#join cannot block the EventLoop thread; continue via an event"
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
    # The callback execution thread is not guaranteed. It may be the caller that
    # registers after settlement, an OffloadPool worker, or a framework control
    # thread. Callbacks must therefore be thread-safe and should complete quickly.
    # A callback failure is logged and does not suppress delivery to other
    # completion callbacks or change the TaskResult's already-settled result.
    #
    # @yield [value, error]
    # @return [self]
    # @api public
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

    # Settles this TaskResult successfully. Framework-owned settlement API.
    # @api private
    def complete(value = nil)
      settle!(:completed, value: value)
    end

    # Settles this TaskResult with a failure. Framework-owned settlement API.
    # @api private
    def fail(error)
      raise ArgumentError, "error is required" unless error
      settle!(:failed, error: error)
    end

    # Settles this TaskResult as cancelled. Framework-owned settlement API.
    #
    # This method does not propagate backwards into a CancellationToken that may
    # have been used to create the TaskResult. Tokens can be shared across operations;
    # operation-wide cancellation is owned by the creating API.
    # @api private
    def cancel!(error = Phronomy::CancellationError.new("TaskResult cancelled"))
      changed = settle!(:cancelled, error: error)
      if changed
        children = @mutex.synchronize { @children.dup }
        children.each { |child| child.cancel!(error) }
      end
      self
    end

    # Creates a derived TaskResult by transforming this TaskResult's successful result.
    # @api public
    def map(&block)
      raise ArgumentError, "map requires a block" unless block

      Concurrency::ResultComposition.new(self, flatten: false, &block).start
    end

    # Transform a successful value into the result of another asynchronous step.
    # The block must return a TaskResult. No implicit wrapping or nested value
    # flattening is performed by map.
    # @return [TaskResult]
    # @api public
    def flat_map(&block)
      raise ArgumentError, "flat_map requires a block" unless block

      Concurrency::ResultComposition.new(self, flatten: true, &block).start
    end

    # Atomic state observation and removable framework subscriptions.
    # @api private
    def __snapshot
      @mutex.synchronize { [@status, @value, @error] }
    end

    # @api private
    def __unsubscribe(callback)
      @mutex.synchronize { @on_complete_callbacks.delete(callback) }
    end

    # Bound at admission, before application code can attach continuations.
    # @api private
    def __bind_execution(execution)
      @execution_scope = execution
      self
    end

    # @api private
    def __execution_scope
      @execution_scope
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
        "[TaskResult] on_complete callback raised #{callback_error.class}: #{callback_error.message}"
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
