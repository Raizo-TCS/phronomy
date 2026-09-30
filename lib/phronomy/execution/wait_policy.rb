# frozen_string_literal: true

module Phronomy
  # Neutral thread-local blocking policy. It owns no Runtime or scheduler.
  # No invocation context is inferred from this marker.
  # @api private
  module WaitPolicy
    KEY = :phronomy_control_thread_depth
    private_constant :KEY

    def self.blocking_forbidden?
      Thread.current.thread_variable_get(KEY).to_i > 0
    end

    def self.without_blocking
      thread = Thread.current
      previous = thread.thread_variable_get(KEY)
      thread.thread_variable_set(KEY, previous.to_i + 1)
      yield
    ensure
      thread.thread_variable_set(KEY, previous)
    end
  end
end
