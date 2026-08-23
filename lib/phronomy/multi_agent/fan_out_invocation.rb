# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # Mutable FSM context for one fan-out operation.
    class FanOutInvocation
      Child = Data.define(:index, :agent, :input, :config)

      attr_reader :phase, :results

      def initialize(children:, max_concurrency:, on_error:)
        @phase = nil
        @children = children
        @max_concurrency = max_concurrency || children.length
        @on_error = on_error
        @pending = children.dup
        @active = {}
        @results = Array.new(children.length)
        @child_errors = Array.new(children.length)
        @fatal_error = nil
        @cancelled = false
        @timed_out = false
      end

      def set_graph_metadata(phase: nil)
        @phase = phase
      end

      def handle_fsm_event(event)
        case event.type
        when :child_completed
          payload = event.payload
          index = payload.fetch(:index)
          @active.delete(index)
          child_error = payload[:error]
          if child_error
            if @on_error == :raise
              @child_errors[index] = child_error
              cancel_active_children! unless @child_errors.any?(&:itself)
            end
          else
            @results[index] = payload[:result]
          end
          true
        when :driver_failed
          @fatal_error ||= event.payload.fetch(:error)
          cancel_active_children!
          true
        when :timeout
          @timed_out = true
          @fatal_error ||= Phronomy::TimeoutError.new(event.payload.fetch(:message))
          cancel_active_children!
          true
        when :cancel
          @cancelled = true
          @fatal_error ||= Phronomy::CancellationError.new("fan-out cancelled")
          cancel_active_children!
          true
        else
          false
        end
      end

      def start_available!(runtime, event_sink:)
        return self if @fatal_error

        while @active.length < @max_concurrency && (child = @pending.shift)
          child_config = build_child_config(child.config)
          handle = child.agent.invoke_async(
            child.input,
            config: child_config
          )
          @active[child.index] = {
            handle: handle,
            token: child_config[:cancellation_token]
          }
          [child.index].each do |captured_index|
            handle.on_complete do |result, error|
              event_sink.post(
                :child_completed,
                {
                  index: captured_index,
                  result: result,
                  error: error
                }
              )
            end
          end
        end
        self
      rescue => caught
        @fatal_error ||= caught
        cancel_active_children!
        event_sink.post(:driver_failed, {error: caught})
        self
      end

      def completed?
        !failed? && @pending.empty? && @active.empty?
      end

      def failed?
        return true if @fatal_error

        @on_error == :raise &&
          @pending.empty? &&
          @active.empty? &&
          @child_errors.any?(&:itself)
      end

      def error
        @fatal_error || @child_errors.find(&:itself)
      end

      def timed_out?
        @timed_out
      end

      def cancelled?
        @cancelled
      end

      private

      def build_child_config(config)
        config.dup
      end

      def cancel_active_children!
        @pending.clear
        @active.each_value do |entry|
          entry[:token]&.cancel!
        end
      end
    end
  end
end
