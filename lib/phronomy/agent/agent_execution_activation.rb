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

      def record_event(event)
        @mutex.synchronize { @runtime_events << event }
        application_listener&.call(event)
      rescue => error
        @mutex.synchronize { @callback_errors << error }
        Phronomy.configuration.logger&.warn(
          "Agent event listener failed: #{error.class}: #{error.message}"
        )
      end
    end
  end
end
