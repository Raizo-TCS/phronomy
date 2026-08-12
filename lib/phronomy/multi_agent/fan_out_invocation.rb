# frozen_string_literal: true

require "securerandom"

module Phronomy
  module MultiAgent
    # Mutable FSM context for one fan-out operation.
    class FanOutInvocation
      Child = Data.define(:index, :agent, :input, :config, :thread_id)

      attr_reader :id, :phase, :results, :error

      def initialize(children:, max_concurrency:, on_error:)
        @id = SecureRandom.uuid.to_s
        @phase = nil
        @children = children
        @max_concurrency = max_concurrency || children.length
        @on_error = on_error
        @pending = children.dup
        @active = {}
        @results = Array.new(children.length)
        @error = nil
        @cancelled = false
        @timed_out = false
        @session_id = nil
      end

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
              @error ||= child_error
              cancel_active_children!
            end
          else
            @results[index] = payload[:result]
          end
          true
        when :driver_failed
          @error ||= event.payload.fetch(:error)
          cancel_active_children!
          true
        when :timeout
          @timed_out = true
          @error ||= Phronomy::TimeoutError.new(event.payload.fetch(:message))
          cancel_active_children!
          true
        when :cancel
          @cancelled = true
          @error ||= Phronomy::CancellationError.new("fan-out cancelled")
          cancel_active_children!
          true
        else
          false
        end
      end

      def start_available!(runtime)
        return self if failed?

        while @active.length < @max_concurrency && (child = @pending.shift)
          child_config = build_child_config(child.config)
          handle = child.agent.invoke_async(
            child.input,
            config: child_config,
            thread_id: child.thread_id
          )
          @active[child.index] = {handle: handle, token: child_config[:cancellation_token]}
          handle.on_complete do |result, error|
            runtime.event_loop.post_to_session(
              Phronomy::Event.new(
                type: :child_completed,
                target_id: @id,
                payload: {index: child.index, result: result, error: error}
              )
            )
          end
        end
        self
      rescue => caught
        @error ||= caught
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
        !@error.nil?
      end

      def timed_out?
        @timed_out
      end

      def cancelled?
        @cancelled
      end

      private

      def build_child_config(config)
        config = config.dup
        upstream = config[:cancellation_token]
        token = Phronomy::Concurrency::CancellationToken.new
        upstream&.on_cancel { token.cancel! }
        config[:cancellation_token] = token
        config
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
