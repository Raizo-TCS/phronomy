# frozen_string_literal: true

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

      def begin_llm_call(projection)
        @mutex.synchronize do
          @runtime_projection = projection
          @active_call = {
            manifest_ref: projection.manifest_ref,
            started_at: Time.now.utc.iso8601(6)
          }
        end
        projection
      end

      def record_llm_result(response:, error:, streaming:)
        @mutex.synchronize do
          active_call = @active_call || {
            manifest_ref: @runtime_projection.manifest_ref,
            started_at: Time.now.utc.iso8601(6)
          }
          @llm_results << {
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
            runtime_events: @runtime_events.dup
          }
        end
      end

      def acknowledge_runtime_snapshot(snapshot)
        @mutex.synchronize do
          @llm_results.shift(snapshot.fetch(:llm_results).length)
          @runtime_events.shift(snapshot.fetch(:runtime_events).length)
        end
      end

      # Immutable record of a non-terminal Application callback failure.
      ApplicationCallbackFailure = Data.define(:event_type, :error) do
        def to_stream_callback_error
          wrapped = Phronomy::StreamCallbackError.new(
            event_type: event_type,
            original_error: error,
            result: nil
          )
          begin
            raise wrapped, cause: error
          rescue Phronomy::StreamCallbackError => e
            e.set_backtrace(error.backtrace)
            e
          end
        end
      end

      attr_reader :callback_failure

      def callback_failed?
        @mutex.synchronize { !@callback_failure.nil? }
      end

      def record_event(event)
        # Skip delivery if a prior callback already failed.
        return if callback_failed?

        @mutex.synchronize { @runtime_events << event }
        application_listener&.call(event)
      rescue => cb_error
        failure = ApplicationCallbackFailure.new(event_type: event.type, error: cb_error)
        @mutex.synchronize do
          @callback_failure = failure
          @application_listener = nil
        end

        notify_callback_failure(failure)
      end

      private

      def notify_callback_failure(failure)
        invocation = @mutex.synchronize { @invocation }
        # FSMSession is created with id: invocation.id; session_id is only set at finish!/halt!.
        session_id = invocation&.id

        if session_id
          runtime = Phronomy::Runtime.instance
          accepted = runtime.event_loop.post_to_session(
            Phronomy::Event.new(
              type: :application_callback_failed,
              target_id: session_id,
              payload: {failure: failure}
            )
          )
          unless accepted
            Phronomy.configuration.logger&.warn(
              "[Phronomy] Callback failure recorded but could not notify FSM: " \
              "execution_id=#{@execution_id} event_type=#{failure.event_type}"
            )
          end
        end

        Phronomy.configuration.logger&.warn(
          "[Phronomy] Application event listener failed: " \
          "#{failure.error.class}: #{failure.error.message}"
        )
      end
    end
  end
end
