# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # Converts Agent events to correlated Workflow events. PipelineState owns
    # stale-result rejection and all Workflow state mutation.
    class AgentResultReceiver
      def draft_listener(workflow:, workflow_instance_id:, request_id:)
        agent_listener(:draft, workflow, workflow_instance_id, request_id) do |output|
          draft_payload(output)
        end
      end

      def review_listener(workflow:, workflow_instance_id:, request_id:)
        agent_listener(:review, workflow, workflow_instance_id, request_id) do |output|
          review_payload(output)
        end
      end

      private

      def draft_payload(output)
        parsed = output
        {
          draft: parsed.fetch("answer"),
          self_score: parsed.fetch("confidence"),
          citations: parsed.fetch("citations")
        }
      end

      def review_payload(output)
        parsed = output
        {
          review_score: parsed.fetch("score"),
          approved: parsed.fetch("approved"),
          feedback: parsed.fetch("feedback")
        }
      end

      def agent_listener(phase, workflow, workflow_instance_id, request_id, &completion)
        ->(agent_event) {
          case agent_event.type
          when :done
            begin
              if agent_event.payload[:rejected]
                workflow.signal(workflow_instance_id: workflow_instance_id,
                  event: :"#{phase}_rejected", payload: {request_id: request_id})
                next
              end
              payload = completion.call(agent_event.payload[:output])
              workflow.signal(
                workflow_instance_id: workflow_instance_id,
                event: :"#{phase}_completed",
                payload: {request_id: request_id, **payload}
              )
            rescue => error
              signal_failure(workflow, workflow_instance_id, request_id, phase, error)
            end
          when :error, :timeout, :cancelled
            error = agent_event.payload[:error] ||
              Phronomy::Error.new("#{phase.to_s.capitalize} Agent ended with #{agent_event.type}")
            signal_failure(workflow, workflow_instance_id, request_id, phase, error)
          end
        }
      end

      def signal_failure(workflow, workflow_instance_id, request_id, phase, error)
        workflow.signal(
          workflow_instance_id: workflow_instance_id,
          event: error.is_a?(Phronomy::Agent::OutputError) ? :"#{phase}_output_failed" : :"#{phase}_failed",
          payload: {request_id: request_id, error: error}
        )
      end
    end
  end
end
