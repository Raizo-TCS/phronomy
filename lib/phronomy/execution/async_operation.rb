# frozen_string_literal: true

module Phronomy
  # Completion adaptation for framework operations. Owns start-error capture,
  # once-only propagation, error-to-value policy and physical completion tracking.
  # Callers supply domain transformations, never completion setters or callbacks.
  # @api private
  module AsyncOperation
    def self.map(source, name:, on_error: nil, &transform)
      raise ArgumentError, "async mapping requires a block" unless transform
      unless source.respond_to?(:on_complete)
        raise TypeError, "asynchronous operation must return a completion handle"
      end
      Concurrency::ResultComposition.new(source, flatten: false, name: name,
        completion_only: true, recover: on_error, &transform).start
    end

    # Capture synchronous preparation/start errors under the same domain policy.
    def self.call(name:, on_error: nil, transform: ->(value) { value })
      source = begin
        yield
      rescue => error
        TaskResult.failed(error, name: name)
      end
      map(source, name: name, on_error: on_error, &transform)
    end

    # Short synchronous fallback/validation only; never offloads or awaits work.
    def self.capture(name:, on_error: nil)
      value = yield
      TaskResult.completed(value, name: name)
    rescue => error
      begin
        raise error unless on_error
        TaskResult.completed(on_error.call(error), name: name)
      rescue => failure
        TaskResult.failed(failure, name: name)
      end
    end
  end
end
