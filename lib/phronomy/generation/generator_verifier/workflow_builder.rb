# frozen_string_literal: true

require "securerandom"

module Phronomy
  class GeneratorVerifier
    # Builds the generation/review loop; result reception does not mutate state.
    class WorkflowBuilder
      def initialize(
        draft_agent:, review_agent:,
        draft_prompt_builder:, review_prompt_builder:,
        draft_result_parser:, review_result_parser:,
        threshold:, max_iterations:
      )
        @draft_agent = draft_agent
        @review_agent = review_agent
        @draft_prompt_builder = draft_prompt_builder
        @review_prompt_builder = review_prompt_builder
        @threshold = threshold
        @max_iterations = max_iterations
        @result_receiver = AgentResultReceiver.new(
          draft_result_parser: draft_result_parser,
          review_result_parser: review_result_parser
        )
      end

      def build
        # The entry closures see the Workflow assigned after definition.
        workflow = nil
        draft_entry = ->(state) { start_draft(state, workflow) }
        review_entry = ->(state) { start_review(state, workflow) }
        finalize_entry = method(:finalize)
        failed_entry = method(:fail_pipeline)
        ready_to_finalize = method(:ready_to_finalize?)

        workflow = Phronomy::Workflow.define(PipelineState) do
          initial :draft

          state :draft
          state :review
          state :finalize
          state :failed

          entry :draft, draft_entry
          entry :review, review_entry
          entry :finalize, finalize_entry
          entry :failed, failed_entry

          transition from: :draft, on: :draft_completed, to: :review
          transition from: :draft, on: :draft_failed, to: :failed
          transition from: :review,
            on: :review_completed,
            guard: ready_to_finalize,
            to: :finalize
          transition from: :review, on: :review_completed, to: :draft
          transition from: :review, on: :review_failed, to: :failed

          transition from: :finalize, to: :__finish__
        end
      end

      private

      def start_draft(state, workflow)
        request_id = SecureRandom.uuid
        next_state = state.merge(draft_request_id: request_id)
        feedback = next_state.review_notes.last
        prompt = @draft_prompt_builder.call(next_state.input, feedback)
        listener = @result_receiver.draft_listener(
          workflow: workflow,
          workflow_instance_id: next_state.workflow_instance_id,
          request_id: request_id
        )
        @draft_agent.send(:__invoke_async_with_event_sink, prompt, on_event: listener)
        next_state
      end

      def start_review(state, workflow)
        request_id = SecureRandom.uuid
        next_state = state.merge(review_request_id: request_id)
        prompt = @review_prompt_builder.call(
          next_state.input, next_state.draft, next_state.citations
        )
        listener = @result_receiver.review_listener(
          workflow: workflow,
          workflow_instance_id: next_state.workflow_instance_id,
          request_id: request_id
        )
        @review_agent.send(:__invoke_async_with_event_sink, prompt, on_event: listener)
        next_state
      end

      def ready_to_finalize?(state)
        confidence = [state.self_score || 0.0, state.review_score || 0.0].min
        (confidence >= @threshold && state.approved) ||
          state.iteration >= @max_iterations
      end

      def finalize(state)
        state.output = state.draft
        state
      end

      def fail_pipeline(state)
        raise(
          state.pipeline_error ||
          Phronomy::Error.new("GeneratorVerifier Agent operation failed")
        )
      end
    end
  end
end
