# frozen_string_literal: true

module Phronomy
  # Internal lifecycle/delivery contract for feature-owned execution state.
  # A receiver has one serial owner supplied by composition, not an application
  # callback SPI. Normal mutation and delivery run only on that owner. idle?
  # runs under its lifecycle lock and must not acquire that lock again.
  # shutdown runs on the failing owner or exclusively after it joins.
  # @api private
  class ExecutionReceiver
    def self.install_binding(provider)
      raise ArgumentError, "Execution receiver provider must be callable" unless provider.respond_to?(:call)
      @binding_provider = provider
    end

    def self.for(owner)
      ExecutionReceiver.binding.receiver(self, owner)
    end

    def self.existing_for(owner)
      ExecutionReceiver.binding.existing_receiver(self, owner)
    end

    def self.binding
      @binding_provider&.call || raise(ConfigurationError, "Execution receiver binding has not been configured")
    end

    def initialize(channel:)
      @channel = channel
    end

    def __bound_to?(owner)
      @channel.bound_to?(owner)
    end

    def idle?
      raise NotImplementedError
    end

    def deliver(message)
      raise NotImplementedError
    end

    def shutdown(error:)
      raise NotImplementedError
    end

    def session_retired(fsm_session_id, reason:)
    end

    private

    def synchronize(&block)
      @channel.synchronize(&block)
    end

    def admit(&block)
      @channel.admit(self, &block)
    end

    def post_message(message, admission: false, completion: nil)
      @channel.post(self, message, admission: admission, completion: completion)
    end

    # Resolve a live routing target atomically with delivery. The channel owns
    # the transport envelope; domain receivers return only a target identity.
    def route_event(type:, payload: nil, &block)
      @channel.route(self, type: type, payload: payload, &block)
    end

    def assert_event_loop_thread!
      return if @channel.current?

      raise Phronomy::Error,
        "Phronomy-managed live execution state may only be mutated on EventLoop"
    end
  end
end
