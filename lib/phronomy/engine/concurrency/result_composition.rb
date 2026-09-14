# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Shared map/flat_map implementation, including the private physical-work
    # boundary. Observing a result never mutates that result or its cancellation.
    # @api private
    class ResultComposition
      def initialize(source, flatten:, &block)
        @source = source
        @scope = source.__execution_scope
        @flatten = flatten
        @block = block
        physical = flatten || source.respond_to?(:on_physical_complete)
        klass = physical ? PhysicalCompletionTask : TaskResult
        @result = klass.deferred(name: "#{source.name}-#{flatten ? "flat-mapped" : "mapped"}",
          parent: source.parent).__bind_execution(@scope)
        @mutex = Mutex.new
        @phase = :waiting
        @source_physical = !source.respond_to?(:on_physical_complete)
        @work_done = false
        @inner_physical = true
        @subscriptions = Subscriptions.new
      end

      def start
        unless @source_physical
          @source.on_physical_complete do
            @mutex.synchronize { @source_physical = true }
            finish_physical
          end
        end
        @subscriptions.result(@source) { receive_source }
        if @scope
          @subscriptions.cancellation(@scope.__cancellation_token) { suppress }
          suppress unless @scope.__open?
        end
        @result
      end

      private

      def receive_source
        status, value, error = @source.__snapshot
        if status != :completed
          started = @mutex.synchronize do
            next false unless @phase == :waiting
            @phase = :finished
            @work_done = true
            true
          end
          if started
            finish_physical
            propagate(status, value, error)
            @subscriptions.close
          end
          return
        end

        claim = lambda do
          @mutex.synchronize do
            next false unless @phase == :waiting
            @phase = :running
            true
          end
        end
        allowed = @scope ? @scope.__while_open(&claim) : claim.call
        unless allowed
          suppress
          return
        end

        begin
          transformed = @block.call(value)
          if @flatten && !transformed.is_a?(TaskResult)
            raise TypeError, "flat_map block must return a Phronomy::TaskResult"
          end
          track_inner_physical(transformed) if @flatten
          @mutex.synchronize do
            @work_done = true
            @phase = :inner unless @phase == :suppressed
          end
          finish_physical
          if @flatten
            unless @result.done?
              @subscriptions.result(transformed) do
                propagate(*transformed.__snapshot)
                @subscriptions.close
              end
            end
          else
            @result.complete(transformed)
            @subscriptions.close
          end
        rescue => error
          @mutex.synchronize { @work_done = true }
          finish_physical
          @result.fail(error)
          @subscriptions.close
        ensure
          # Even an exception deliberately outside StandardError cannot leave
          # already-finished Ruby work looking physically active.
          @mutex.synchronize { @work_done = true }
          finish_physical
        end
      end

      def suppress
        @mutex.synchronize do
          @work_done = true if @phase == :waiting
          @phase = :suppressed
        end
        finish_physical
        @result.cancel!(@scope.__cancellation_error)
        @subscriptions.close
      end

      def propagate(status, value, error)
        case status
        when :completed then @result.complete(value)
        when :cancelled then @result.cancel!(error)
        when :failed then @result.fail(error)
        end
      end

      def track_inner_physical(inner)
        return unless inner.respond_to?(:on_physical_complete)
        return unless inner.__execution_scope.equal?(@scope)

        @mutex.synchronize { @inner_physical = false }
        inner.on_physical_complete do
          @mutex.synchronize { @inner_physical = true }
          finish_physical
        end
      end

      def finish_physical
        return unless @result.respond_to?(:mark_physical_complete!)

        done = @mutex.synchronize { @source_physical && @work_done && @inner_physical }
        @result.mark_physical_complete! if done
      end
    end
  end
end
