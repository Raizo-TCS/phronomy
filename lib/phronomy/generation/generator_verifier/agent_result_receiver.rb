# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
    # Converts Agent events to correlated Workflow events. PipelineState owns
    # stale-result rejection and all Workflow state mutation.
    class AgentResultReceiver
      def initialize(draft_result_parser:, review_result_parser:)
        @draft_result_parser = draft_result_parser
        @review_result_parser = review_result_parser
      end

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
        parsed = @draft_result_parser.call(output)
        {
          draft: parsed[:answer].to_s,
          self_score: clamp(parsed[:confidence]),
          citations: normalize_citations(parsed[:citations])
        }
      end

      def review_payload(output)
        parsed = @review_result_parser.call(output)
        {
          review_score: clamp(parsed[:score]),
          approved: parsed[:approved] == true,
          feedback: parsed[:feedback].to_s
        }
      end

      def agent_listener(phase, workflow, workflow_instance_id, request_id, &completion)
        ->(agent_event) {
          case agent_event.type
          when :done
            begin
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
          when :approval_required
            error = Phronomy::Error.new("GeneratorVerifier #{phase} Agent suspended for approval")
            signal_failure(workflow, workflow_instance_id, request_id, phase, error)
          end
        }
      end

      def signal_failure(workflow, workflow_instance_id, request_id, phase, error)
        workflow.signal(
          workflow_instance_id: workflow_instance_id,
          event: :"#{phase}_failed",
          payload: {request_id: request_id, error: error}
        )
      end

      def clamp(value)
        value.to_f.clamp(0.0, 1.0)
      end

      def normalize_citations(raw)
        Array(raw).filter_map do |citation|
          citation.is_a?(Hash) ? citation.transform_keys(&:to_sym) : nil
        end
      end
    end
  end
end
