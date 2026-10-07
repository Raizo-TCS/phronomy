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

      def start(input, listener:)
        request = Object.new
        # Workflow entry calls are serial. Keep submitted requests until their
        # own result settles: Agent admission itself may run after an earlier
        # request completes, so a pending submission is not necessarily busy.
        @mutex.synchronize { @pending << [request, listener] }
        task = @agent.invoke_async(input)
        task.on_complete do |result, error|
          release(request)
          # Handoff was not a generation completion in the event-based path.
          next if !error && result.is_a?(Hash) && result[:handoff_request]

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

      private

      def receive_event(event)
        return unless event.type == :approval_required

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
