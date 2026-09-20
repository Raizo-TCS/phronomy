# frozen_string_literal: true

module Phronomy
  # Thread-free fan-out/fan-in. Each input block returns the final TaskResult for
  # that JOB; its application-defined intermediate work is not discovered here.
  # @api public
  class Execution
    # @return [InvocationContext] this execution's explicit operation context
    # @api public
    attr_reader :invocation_context

    # @param inputs [Array] shallowly snapshotted JOB inputs
    # @param timeout [Numeric, nil] whole-execution deadline in seconds
    # @param cancellation_token [Concurrency::CancellationToken, nil]
    # @param invocation_context [InvocationContext, nil] existing information/controls
    # @yield [input, execution] starts one JOB and returns its final TaskResult
    # @return [TaskResult<Array<TaskResult::Outcome>>]
    # @api public
    def self.run_async(inputs, timeout: nil, cancellation_token: nil,
      invocation_context: nil, &block)
      __run_async(inputs, timeout: timeout, cancellation_token: cancellation_token,
        invocation_context: invocation_context, &block)
    end

    # Starts the same execution once and waits outside EventLoop.
    # @return [Array<TaskResult::Outcome>]
    # @see run_async
    # @api public
    def self.run(inputs, timeout: nil, cancellation_token: nil,
      invocation_context: nil, &block)
      if Runtime.in_event_loop_context?
        raise EventLoopReentrancyError, "Execution.run cannot run on EventLoop; use run_async"
      end
      run_async(inputs, timeout: timeout, cancellation_token: cancellation_token,
        invocation_context: invocation_context, &block).wait_result
    end

    # Existing Orchestrator concurrency policy uses the same execution engine.
    # This is not an additional public execution entrance or scheduling mode.
    # @api private
    def self.__run_async(inputs, timeout: nil, cancellation_token: nil,
      invocation_context: nil, concurrency_limit: nil, &block)
      raise TypeError, "inputs must be an Array" unless inputs.is_a?(Array)
      raise ArgumentError, "Execution.run_async requires a block" unless block
      if !cancellation_token.nil? && !cancellation_token.is_a?(Concurrency::CancellationToken)
        raise TypeError, "cancellation_token must be a Phronomy::Concurrency::CancellationToken or nil"
      end
      if !invocation_context.nil? && !invocation_context.is_a?(InvocationContext)
        raise TypeError, "invocation_context must be a Phronomy::InvocationContext or nil"
      end
      unless timeout.nil?
        raise TypeError, "timeout must be Numeric or nil" unless timeout.is_a?(Numeric)
        if timeout.is_a?(Complex) || !timeout.finite? || !timeout.to_f.finite?
          raise ArgumentError, "timeout must be a finite real number"
        end
      end
      new(inputs.dup, timeout: timeout, cancellation_token: cancellation_token,
        invocation_context: invocation_context, concurrency_limit: concurrency_limit,
        &block).send(:start)
    end
    private_class_method :__run_async

    # Common admission binding for Agent and synchronous-work adapters.
    # @api private
    def self.__operation_binding(invocation_context:, cancellation_token:)
      Concurrency::OperationBinding.new(invocation_context: invocation_context,
        cancellation_token: cancellation_token)
    end

    # A scoped observation copy. The source, its controls and its physical work
    # keep their original ownership. Bind before adding this run's map/flat_map.
    # @param source_result [TaskResult]
    # @return [TaskResult] a distinct scoped observation result
    # @raise [TypeError] for a non-TaskResult source
    # @api public
    def observe(source_result)
      unless source_result.is_a?(TaskResult)
        raise TypeError, "source_result must be a Phronomy::TaskResult"
      end
      observed = TaskResult.deferred(name: "execution-observation").__bind_execution(self)
      subscriptions = Concurrency::Subscriptions.new
      subscriptions.result(observed) { subscriptions.close }
      unless __open?
        observed.cancel!(__cancellation_error)
        return observed
      end
      subscriptions.result(source_result) do
        status, value, error = source_result.__snapshot
        if !__open? && status == :completed
          observed.cancel!(__cancellation_error)
        elsif status == :completed
          observed.complete(value)
        elsif status == :cancelled
          observed.cancel!(error)
        else
          observed.fail(error)
        end
      end
      subscriptions.cancellation(@token) { observed.cancel!(__cancellation_error) }
      observed
    end

    # Scope/admission hooks shared with framework-owned operations.
    # @api private
    def __while_open(&block)
      @collector.while_open(&block)
    end

    # @api private
    def __open?
      @collector.open?
    end

    # @api private
    def __cancellation_token
      @token
    end

    # @api private
    def __cancellation_error
      @cancellation_error
    end

    private

    def initialize(inputs, timeout:, cancellation_token:, invocation_context:,
      concurrency_limit:, &block)
      @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @inputs = inputs
      @block = block
      @timeout = timeout
      @parent_context = invocation_context
      @parent_token = cancellation_token
      @token = Concurrency::CancellationToken.new
      @subscriptions = Concurrency::Subscriptions.new
      @cancellation_error = CancellationError.new("Execution scope is closed")
      @invocation_context = (invocation_context || InvocationContext.new)
        .merge(cancellation_token: @token).__bind_execution(self)
      @result = TaskResult.deferred(name: "execution")
      @pump_mutex = Mutex.new
      @next_index = 0
      @active = 0
      @draining = false
      @limit = concurrency_limit || [inputs.length, 1].max
      @collector = Concurrency::ResultCollector.new(inputs.length) do |kind, outcomes|
        finish(kind, outcomes)
      end
    end

    def start
      # All slots and control state exist before any registration can fire.
      [@parent_token, @parent_context&.cancellation_token].compact.uniq.each do |token|
        @subscriptions.cancellation(token) { @collector.finish(:cancelled) }
      end
      if @parent_context&.__execution_scope && !@parent_context.__execution_scope.__open?
        @collector.finish(:cancelled)
      end
      if @parent_context&.deadline
        @subscriptions.after(@parent_context.deadline.remaining_seconds) { @collector.finish(:cancelled) }
      end
      if @timeout
        remaining = @timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at)
        @subscriptions.after(remaining) { @collector.finish(:timeout) }
      end
      @collector.finish(:completed) if @inputs.empty?
      drain
      @result
    end

    def drain
      claimed = @pump_mutex.synchronize do
        next false if @draining
        @draining = true
      end
      return unless claimed

      loop do
        work = @collector.while_open do
          @pump_mutex.synchronize do
            if @active < @limit && @next_index < @inputs.length
              index = @next_index
              @next_index += 1
              @active += 1
              [index, @inputs[index], @block]
            else
              @draining = false
              nil
            end
          end
        end
        unless work
          @pump_mutex.synchronize { @draining = false } unless __open?
          break
        end
        index, input, start_block = work
        begin
          result = start_block.call(input, self)
          unless result.is_a?(TaskResult)
            raise TypeError, "JOB at inputs[#{index}] must return a Phronomy::TaskResult"
          end
        rescue => error
          result = TaskResult.failed(error, name: "execution-job-#{index}")
        end
        @collector.watch(index, result) do
          @pump_mutex.synchronize { @active -= 1 }
          drain
        end
      end
    end

    def finish(kind, outcomes)
      @subscriptions.close
      # A retained scoped result needs the closed-scope gate, not all original
      # inputs and the application start closure. A claimed start keeps its own
      # local copy so cancellation during admission does not invalidate it.
      @pump_mutex.synchronize do
        @inputs = []
        @block = nil
      end
      case kind
      when :completed
        @result.complete(outcomes)
      when :timeout
        @cancellation_error = CancellationError.new("Execution deadline exceeded")
        error = ExecutionTimeoutError.new(outcomes: outcomes)
        @token.cancel!
        @result.fail(error)
      when :cancelled
        @cancellation_error = CancellationError.new("Execution cancelled")
        error = ExecutionCancellationError.new(outcomes: outcomes)
        @token.cancel!
        @result.cancel!(error)
      end
    end
  end
end
