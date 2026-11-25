# frozen_string_literal: true

module Phronomy
  module Agent
    # Tracks only the progress messages crossing one dispatch handoff. A helper
    # returning normally does not prove these messages were accepted. After the
    # handoff seals, ordinary asynchronous delivery keeps its existing contract.
    # @api private
    class DispatchContinuationDelivery
      PROGRESS_EVENTS = %i[
        llm_setup_failed llm_failed llm_completed tool_setup_failed tool_dispatch_prepared
        tool_failed tool_completed tool_cancelled tool_rejected tool_authorized tool_approval_required
      ].freeze
      Entry = Struct.new(:type, :payload, :state)
      private_constant :PROGRESS_EVENTS, :Entry

      def initialize(event_sink:)
        @event_sink = event_sink
        @mutex = Mutex.new
        @entries = []
        @sealed = @unknown = @retrying = false
      end

      def fsm_session_id = @event_sink.fsm_session_id

      def post(type, payload)
        unless PROGRESS_EVENTS.include?(type)
          return @event_sink.post(type, payload)
        end
        captured = Phronomy::Values::Immutable.copy(payload)
        entry = @mutex.synchronize do
          next if @sealed
          Entry.new(type, captured, :in_flight).tap { |value| @entries << value }
        end
        return @event_sink.post(type, payload) unless entry
        deliver(entry)
      end

      # Only an explicit false establishes non-admission. Repeating this method
      # resends those exact messages, never Provider/Tool work or unknown sends.
      def retry_rejected!
        acquired = @mutex.synchronize do
          return true if @sealed
          return false if @unknown || @retrying || @entries.any? { |entry| entry.state == :in_flight }
          @retrying = true
        end
        loop do
          entry = @mutex.synchronize do
            next if @unknown
            @entries.find { |value| value.state == :rejected }&.tap { |value| value.state = :in_flight }
          end
          break unless entry
          return false unless deliver(entry).equal?(true)
        end
        @mutex.synchronize { !@unknown && @entries.empty? }
      ensure
        @mutex.synchronize { @retrying = false } if acquired
      end

      # Reservation of an in-flight post and sealing share one lock. No delegate
      # call runs under that lock, including a retry with synchronous callbacks.
      def finish_handoff?
        @mutex.synchronize do
          return true if @sealed
          return false if @unknown || @retrying || !@entries.empty?
          @sealed = true
        end
      end

      private

      def deliver(entry)
        accepted = @event_sink.post(entry.type, entry.payload)
        @mutex.synchronize do
          if accepted.equal?(true)
            @entries.delete_if { |value| value.equal?(entry) }
          elsif accepted.equal?(false)
            entry.state = :rejected
          else
            entry.state = :unknown
            @unknown = true
          end
        end
        accepted
      rescue Exception # rubocop:disable Lint/RescueException
        # An accepted send may raise while returning its receipt. Never infer
        # non-admission or replay from an exception, including control exits.
        @mutex.synchronize do
          entry.state = :unknown
          @unknown = true
        end
        raise
      end
    end
  end
end
