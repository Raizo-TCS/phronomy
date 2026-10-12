# frozen_string_literal: true

module Phronomy
  # A revocable, process-local completion address. The callback retains only
  # this address; closing it drops its source and receiver, not the source work.
  # @api private
  class WorkflowTaskReception
    Notification = Data.define(:reception, :status, :value, :error)
    DeliveryFailure = Data.define(:reception, :error)
    Cancellation = Data.define(:reception)

    attr_reader :owner_token

    def initialize(registry:, owner_token:)
      @registry = registry
      @owner_token = owner_token
      @mutex = Mutex.new
      @source = nil
      @notified = false
    end

    def watch(source)
      @mutex.synchronize { @source = source if @registry }
      source.on_complete(&method(:completed))
    end

    def completed(value, error)
      registry, source = claim
      return unless registry

      deliver(registry, Notification.new(reception: self,
        status: source.status, value: value, error: error))
    end

    def cancelled
      registry, = claim
      deliver(registry, Cancellation.new(reception: self)) if registry
    end

    def close
      @mutex.synchronize do
        @registry = nil
        @source = nil
      end
      nil
    end

    def active?
      @mutex.synchronize { !@registry.nil? }
    end

    private

    def claim
      @mutex.synchronize do
        return [nil, nil] if @notified || !@registry

        @notified = true
        [@registry, @source]
      end
    end

    def deliver(registry, command)
      return if registry.post(command)

      registry.task_delivery_failed(self,
        Phronomy::RuntimeShutdownError.new("Runtime rejected Workflow task completion"))
    rescue => error
      registry.task_delivery_failed(self, error)
    end
  end
end
