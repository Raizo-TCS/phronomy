# frozen_string_literal: true

module Phronomy
  # C02 owns which state admission may consume a TaskResult. The injected
  # connection applies context/terminal decisions to the concrete state machine.
  # @api private
  class WorkflowTaskExecution
    attr_reader :result_task, :owner_token, :cancelled_error

    def initialize(definitions:, registry:, environment:, owner_token:, result_task:, cancellation_token: nil)
      unless cancellation_token.nil? || cancellation_token.is_a?(Phronomy::Concurrency::CancellationToken)
        raise TypeError, "cancellation_token must be a Phronomy::Concurrency::CancellationToken or nil"
      end
      @definitions = definitions
      @registry = registry
      @environment = environment
      @owner_token = owner_token
      @result_task = result_task
      @cancellation_token = cancellation_token
      @connection = nil
      @reception = nil
      @state_name = nil
      @applied = false
      @closed = false
    end

    def bind(connection)
      @connection = connection
    end

    def activate
      if @registry.draining?
        stop(Phronomy::RuntimeShutdownError.new("Runtime is stopping Workflow task execution"))
      elsif @cancellation_token&.cancelled?
        cancel
      elsif @cancellation_token
        @cancel_reception = WorkflowTaskReception.new(registry: @registry, owner_token: @owner_token)
        @cancel_subscription = @environment.subscribe_cancellation(
          @cancellation_token, &@cancel_reception.method(:cancelled)
        )
      end
    end

    # Called after synchronous entry. true suppresses automatic completion.
    def enter(state_name, context)
      if @state_name != state_name
        leave
        @state_name = state_name
        @entry_key = Object.new.freeze
      end
      return false unless @definitions.key?(state_name)
      return !@applied if @reception || @applied

      @reception = WorkflowTaskReception.new(registry: @registry, owner_token: @owner_token)
      snapshot = context.merge({})
      snapshot.set_graph_metadata(phase: state_name)
      source = @definitions.fetch(state_name).fetch(:start).call(snapshot)
      unless source.is_a?(Phronomy::TaskResult)
        raise TypeError, "task_state #{state_name.inspect} start must return Phronomy::TaskResult"
      end
      @reception.watch(source)
      true
    end

    # Queued automatic progression must belong to the same entry as the
    # applied result, even if an external transition wins before dispatch.
    def completion_key
      return if @closed || (@definitions.key?(@state_name) && !@applied)

      @entry_key
    end

    def permits_completion?(key)
      key&.equal?(completion_key)
    end

    def receive(notification)
      return unless current?(notification.reception)

      definition = @definitions.fetch(@state_name)
      @reception.close
      @reception = nil
      case notification.status
      when :completed
        context = @connection.context
        updated = definition.fetch(:apply).call(context, notification.value)
        unless updated.nil? || updated.is_a?(context.class)
          raise TypeError, "task_state #{@state_name.inspect} apply must return its WorkflowContext or nil"
        end
        @applied = true
        @connection.apply_task_context(updated || context)
      when :cancelled
        cancel(notification.error)
      when :failed
        stop(notification.error)
      else
        raise TypeError, "task_state received nonterminal TaskResult status #{notification.status.inspect}"
      end
    rescue => error
      stop(error)
    end

    def delivery_failed(reception, error)
      stop(error) if current?(reception) || (!@closed && reception.equal?(@cancel_reception))
    end

    def receive_cancellation(reception)
      cancel if !@closed && reception.equal?(@cancel_reception)
    end

    def cancel(error = nil)
      return if @closed

      @cancelled_error = error || Phronomy::CancellationError.new("Workflow task execution cancelled")
      stop(@cancelled_error)
    end

    def stop(error)
      @connection&.fail_task_execution(error) unless @closed
    end

    def leave
      @reception&.close
      @reception = nil
      @state_name = nil
      @entry_key = nil
      @applied = false
    end

    def close
      return if @closed

      @closed = true
      leave
      @cancel_reception&.close
      @cancel_subscription&.close
      @cancel_reception = @cancel_subscription = @cancellation_token = nil
      @connection = nil
    end

    # Unknown durable outcomes retain admission, but are still observable.
    def retire(error)
      close
      @result_task.fail(error)
    end

    private

    def current?(reception)
      !@closed && reception.equal?(@reception) && @connection.current_state == @state_name
    end
  end
end
