# frozen_string_literal: true

module Phronomy
  class Runtime
    # Immutable result returned by {Runtime#shutdown}.
    #
    # +runtime_outcome+ records whether execution remained healthy. It is
    # intentionally independent from +cleanup_status+: a Runtime may fail
    # during execution but still release every owned resource successfully.
    # @api private
    class ShutdownResult
      attr_reader :runtime_outcome,
        :cleanup_status,
        :event_loop_status,
        :task_registry_status,
        :error

      def self.not_started
        new(
          runtime_outcome: :terminated,
          cleanup_status: :complete,
          event_loop_status: :not_started,
          task_registry_status: :empty
        )
      end

      def initialize(
        runtime_outcome:,
        cleanup_status:,
        event_loop_status:,
        task_registry_status:,
        error: nil
      )
        @runtime_outcome = runtime_outcome
        @cleanup_status = cleanup_status
        @event_loop_status = event_loop_status
        @task_registry_status = task_registry_status
        @error = error
        freeze
      end

      # Returns true when owned resources stopped and pending timer notifications
      # settled within the shutdown budget rather than being discarded.
      def cleanup_complete?
        @cleanup_status == :complete
      end

      # Returns true only for a graceful, error-free shutdown.
      # A cancellation may release every resource, but is not considered clean.
      def clean?
        @runtime_outcome == :terminated &&
          @cleanup_status == :complete &&
          %i[not_started terminated].include?(@event_loop_status) &&
          @task_registry_status == :empty
      end
    end
  end
end
