# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # Connects one reused Agent incarnation through its public operation and
    # notification contracts. Terminal results belong to each returned TaskResult;
    # only approval suspension needs the incarnation listener while that Task is
    # still pending. Generation owns the request-to-Workflow correlation.
    # @api private
    class AgentOperation
      def initialize(agent_class)
        @mutex = Mutex.new
        @pending = []
        @agent = agent_class.new(on_event: method(:receive_event))
      end

      def start(input, listener:, config: {})
        request = Object.new
        # Workflow entry calls are serial. Keep submitted requests until their
        # own result settles: Agent admission itself may run after an earlier
        # request completes, so a pending submission is not necessarily busy.
        @mutex.synchronize { @pending << [request, listener] }
        task = @agent.invoke_async(input, config: config)
        task.on_complete do |result, error|
          release(request)
          remember_execution(result[:execution_id]) if result.is_a?(Hash)
          if !error && result.is_a?(Hash) && result[:handoff_request]
            error = Phronomy::Error.new("GeneratorVerifier does not coordinate Handoff",
              code: "generation.unsupported_handoff")
          end

          event = if error
            type = if error.is_a?(Phronomy::TimeoutError)
              :timeout
            elsif error.is_a?(Phronomy::CancellationError)
              :cancelled
            else
              :error
            end
            Phronomy::Agent::StreamEvent.new(type: type, payload: {error: error})
          else
            Phronomy::Agent::StreamEvent.new(type: :done, payload: result)
          end
          listener.call(event)
        end
        task
      rescue
        release(request)
        raise
      end

      def approve_async(request, approved:)
        @agent.approve_async(request.execution_id, approval_request_id: request.id, approved: approved)
      end

      def cancel_async
        execution_id = @mutex.synchronize { @execution_id }
        @agent.cancel_async(execution_id) if execution_id
      end

      def unload!
        @agent.unload!
      end

      private

      def remember_execution(execution_id)
        @mutex.synchronize { @execution_id = execution_id } if execution_id
      end

      def receive_event(event)
        return unless event.type == :approval_required
        request = event.payload[:request]
        remember_execution(request.execution_id) if request.respond_to?(:execution_id)

        listener = @mutex.synchronize { @pending.first&.last }
        listener&.call(event)
      end

      def release(request)
        @mutex.synchronize do
          @pending.delete_if { |entry| entry.first.equal?(request) }
        end
      end
    end
  end
end
