# frozen_string_literal: true

module Phronomy
  # Concrete EventLoop transport and lifecycle registration for execution state.
  # @api private
  class ExecutionReceiverBinding
    def self.receiver(receiver_class, event_loop)
      event_loop.__execution_receiver(key: receiver_class) ||
        event_loop.__register_execution_receiver(key: receiver_class,
          receiver: receiver_class.new(channel: new(event_loop)))
    end

    def self.existing_receiver(receiver_class, runtime)
      runtime.__event_loop_if_initialized&.__execution_receiver(key: receiver_class)
    end

    def initialize(event_loop)
      @event_loop = event_loop
    end

    def bound_to?(owner) = @event_loop.equal?(owner)
    def current? = @event_loop.current?

    def synchronize(&block)
      @event_loop.__synchronize_execution_state(&block)
    end

    def admit(receiver, &block)
      @event_loop.__admit_execution(receiver, &block)
    end

    def post(receiver, message, admission:, completion:)
      @event_loop.__post_execution(receiver, message, admission: admission, completion: completion)
    end

    def route(receiver, type:, payload:)
      @event_loop.__route_execution_event(receiver) do
        target = yield
        target && Phronomy::Event.new(type: type, target_id: target, payload: payload)
      end
    end
  end
end
