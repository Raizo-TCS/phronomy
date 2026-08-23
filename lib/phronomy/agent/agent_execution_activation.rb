# frozen_string_literal: true

require "securerandom"
require "time"

module Phronomy
  module Agent
    class AgentExecutionActivation
      attr_reader :execution_id, :agent, :application_listener, :coordinator,
        :base_manifest
      attr_accessor :invocation, :session

      def initialize(
        execution:,
        agent:,
        runtime_projection:,
        coordinator:,
        application_listener: nil
      )
        @execution_id = execution.execution_id
        @execution = execution
        @agent = agent
        @runtime_projection = runtime_projection
        @base_manifest = runtime_projection.manifest
        @coordinator = coordinator
        @application_listener = application_listener
        @mutex = Mutex.new
        @active_call = nil
        @llm_results = []
        @runtime_events = []
        @callback_errors = []
      end

      def execution
        @mutex.synchronize { @execution }
      end

      def replace_execution(value)
        @mutex.synchronize { @execution = value }
      end

      def runtime_projection
        @mutex.synchronize { @runtime_projection }
      end

      def replace_runtime_projection(value)
        @mutex.synchronize { @runtime_projection = value }
      end

      # Allocates Provider Call identity before transport begins. This identity is
      # provenance only; Context selection must not use it as a semantic boundary.
      def begin_llm_call(projection)
        call_context = {
          llm_call_id: SecureRandom.uuid,
          manifest_ref: projection.manifest_ref,
          started_at: Time.now.utc.iso8601(6)
        }.freeze
        @mutex.synchronize do
          if @active_call
            raise Phronomy::Error,
              "cannot start a Provider Call while another Provider Call is active"
          end
          @runtime_projection = projection
          @active_call = call_context
        end
        call_context
      end

      def record_llm_result(response:, error:, streaming:)
        @mutex.synchronize do
          active_call = @active_call
          unless active_call
            raise Phronomy::Error, "LLM result arrived without an active Provider Call"
          end
          @llm_results << {
            llm_call_id: active_call.fetch(:llm_call_id),
            response: response,
            error: error,
            streaming: streaming,
            manifest_ref: active_call.fetch(:manifest_ref),
            started_at: active_call.fetch(:started_at)
          }
          @active_call = nil
        end
      end

      def runtime_snapshot
        @mutex.synchronize do
          {
            llm_results: @llm_results.dup,
            runtime_events: @runtime_events.dup,
            active_call: @active_call&.dup
          }
        end
      end

      def acknowledge_runtime_snapshot(snapshot)
        @mutex.synchronize do
          @llm_results.shift(snapshot.fetch(:llm_results).length)
          @runtime_events.shift(snapshot.fetch(:runtime_events).length)
          if snapshot[:active_call] && @active_call == snapshot[:active_call]
            @active_call = nil
          end
        end
      end

      ApplicationCallbackFailure = Data.define(:event_type, :error) do
        def to_stream_callback_error
          wrapped = Phronomy::StreamCallbackError.new(
            event_type: event_type, original_error: error, result: nil
          )
          begin
            raise wrapped, cause: error
          rescue Phronomy::StreamCallbackError => caught
            caught.set_backtrace(error.backtrace)
            caught
          end
        end
      end

      attr_reader :callback_failure

      def callback_failed?
        @mutex.synchronize { !@callback_failure.nil? }
      end

      # Canonical runtime recording is independent of Application callback health.
      # Once an event is observed it is appended even after a listener has failed.
      def record_event(event, event_sink: nil)
        listener = @mutex.synchronize do
          @runtime_events << event
          @callback_failure ? nil : @application_listener
        end
        return unless listener

        listener.call(event)
      rescue => callback_error
        failure = ApplicationCallbackFailure.new(
          event_type: event.type, error: callback_error
        )
        @mutex.synchronize do
          @callback_failure ||= failure
          @application_listener = nil
        end
        notify_callback_failure(failure, event_sink)
      end

      private

      def notify_callback_failure(failure, event_sink)
        if event_sink
          accepted = event_sink.post(:application_callback_failed, {failure: failure})
          unless accepted
            Phronomy.configuration.logger&.warn(
              "[Phronomy] Callback failure recorded but could not notify " \
              "FSMSession #{event_sink.fsm_session_id}: execution_id=#{@execution_id}"
            )
          end
        end
        Phronomy.configuration.logger&.warn(
          "[Phronomy] Application event listener failed: #{failure.error.class}: #{failure.error.message}"
        )
      end
    end
  end
end
