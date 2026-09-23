# frozen_string_literal: true

module Phronomy
  # Internal lifecycle/delivery contract for feature-owned execution state.
  # Receivers are retained by one EventLoop, not an application callback SPI.
  # Normal mutation and delivery run only on that loop. idle? runs with its
  # lifecycle lock held; it must not call Runtime or acquire that lock again.
  # shutdown runs on a failing loop, or exclusively after a clean loop joins.
  # @api private
  class ExecutionReceiver
    def self.for(event_loop)
      event_loop.__execution_receiver(key: self) ||
        event_loop.__register_execution_receiver(key: self, receiver: new(event_loop: event_loop))
    end

    # Lookup only: neither a loop nor a receiver is created during inspection.
    def self.existing_for(runtime)
      runtime.__event_loop_if_initialized&.__execution_receiver(key: self)
    end

    def initialize(event_loop:)
      @event_loop = event_loop
    end

    def __bound_to?(event_loop)
      @event_loop.equal?(event_loop)
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
      @event_loop.__synchronize_execution_state(&block)
    end

    def admit(&block)
      @event_loop.__admit_execution(self, &block)
    end

    def post_message(message, admission: false, completion: nil)
      @event_loop.__post_execution(self, message, admission: admission, completion: completion)
    end

    def assert_event_loop_thread!
      return if @event_loop.current?

      raise Phronomy::Error,
        "Phronomy-managed live execution state may only be mutated on EventLoop"
    end
  end
end
