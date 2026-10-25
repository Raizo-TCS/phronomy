# frozen_string_literal: true

module Phronomy
  module Concurrency
    # Completion composition for an owner-supplied asynchronous finalizer.
    # This has no cancellation authority and no domain release policy.
    # @api private
    class ResultFinalization
      def initialize(source, name:, cleanup:, on_cleanup_error:)
        @source = source
        @cleanup = cleanup
        @on_cleanup_error = on_cleanup_error
        @result = PhysicalCompletionTask.deferred(name: name)
        @mutex = Mutex.new
        @phase = :source
        @outcomes = {}
        @physical = {}
      end

      def start
        observe(@source, :source)
        @result
      end

      private

      def observe(task, phase)
        physical = task.respond_to?(:on_physical_complete)
        @mutex.synchronize { @physical[phase] = !physical }
        if physical
          task.on_physical_complete do
            @mutex.synchronize { @physical[phase] = true unless @phase == :finished }
            advance
          end
        end
        task.on_complete do |value, error|
          @mutex.synchronize do
            if @phase == phase && !@outcomes.key?(phase)
              status = if error
                (task.status == :cancelled) ? :cancelled : :failed
              else
                :completed
              end
              @outcomes[phase] = [status, value, error]
            end
          end
          advance
        end
      end

      def advance
        action = @mutex.synchronize do
          phase = @phase
          next unless @outcomes.key?(phase) && @physical[phase]
          @phase = (phase == :source) ? :cleanup : :finished
          phase
        end
        case action
        when :source then start_cleanup
        when :cleanup then finish
        end
      end

      def start_cleanup
        task = begin
          value = @cleanup.call
          raise TypeError, "asynchronous cleanup must return a TaskResult" unless value.is_a?(TaskResult)
          value
        rescue => error
          TaskResult.failed(error)
        end
        observe(task, :cleanup)
      end

      def finish
        status, value, error = @outcomes.fetch(:source)
        cleanup_error = @outcomes.fetch(:cleanup).last
        if cleanup_error
          begin
            error = @on_cleanup_error.call(value, error, cleanup_error)
            raise TypeError, "cleanup error policy must return or raise an Exception" unless error.is_a?(Exception)
          rescue => policy_error
            error = policy_error
          end
          status = :failed
        end
        # Completed handles must not keep the owner or its source/cleanup
        # closures alive. A domain cleanup error may deliberately retain them.
        @source = @cleanup = @on_cleanup_error = nil
        @mutex.synchronize do
          @outcomes.clear
          @physical.clear
        end
        begin
          @result.mark_physical_complete!
        ensure
          case status
          when :completed then @result.complete(value)
          when :cancelled then @result.cancel!(error)
          else @result.fail(error)
          end
        end
      end
    end
  end
end
