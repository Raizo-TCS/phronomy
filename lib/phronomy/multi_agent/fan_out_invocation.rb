# frozen_string_literal: true

require "securerandom"

module Phronomy
  module MultiAgent
    # Mutable FSM context for one fan-out operation.
    class FanOutInvocation
      Child = Data.define(:index, :agent, :input, :config)

      attr_reader :id, :phase, :results

      def initialize(children:, max_concurrency:, on_error:)
        @id = SecureRandom.uuid.to_s
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
        @session_id = nil
      end

      # Shared FSMSession Runtime metadata bridge. This is not application
      # invocation identity and remains outside CG-02a.
      def set_graph_metadata(thread_id: nil, phase: nil)
        @session_id = thread_id if thread_id
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

      def start_available!(runtime)
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
              runtime.event_loop.post_to_session(
                Phronomy::Event.new(
                  type: :child_completed,
                  target_id: @id,
                  payload: {
                    index: captured_index,
                    result: result,
                    error: error
                  }
                )
              )
            end
          end
        end
        self
      rescue => caught
        @fatal_error ||= caught
        cancel_active_children!
        runtime.event_loop.post_to_session(
          Phronomy::Event.new(
            type: :driver_failed,
            target_id: @id,
            payload: {error: caught}
          )
        )
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
