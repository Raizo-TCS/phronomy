# frozen_string_literal: true

require "securerandom"

module Phronomy
  # Implements the Generator-Verifier multi-agent coordination pattern.
  #
  # Agent completion is integrated through application-defined Workflow events;
  # Workflow entry actions do not return or await Agent Tasks.
  class GeneratorVerifier
    DEFAULT_CONFIDENCE_THRESHOLD = 0.7
    DEFAULT_MAX_ITERATIONS = 3

    Result = Struct.new(
      :output,
      :confidence,
      :citations,
      :iterations,
      :review_notes,
      :trusted
    ) do
      alias_method :trusted?, :trusted
    end

    class PipelineState
      include Phronomy::WorkflowContext

      field :input, type: :replace, default: -> { "" }
      field :draft, type: :replace, default: -> { {} }
      field :self_score, type: :replace, default: -> { 0.0 }
      field :review_score, type: :replace, default: -> { 0.0 }
      field :citations, type: :replace, default: -> { [] }
      field :review_notes, type: :append, default: -> { [] }
      field :iteration, type: :replace, default: -> { 0 }
      field :approved, type: :replace, default: -> { false }
      field :output, type: :replace, default: -> { {} }
      field :draft_request_id, type: :replace, default: nil
      field :review_request_id, type: :replace, default: nil
      field :pipeline_error, type: :replace, default: nil

      # Application-level event interpretation. Correlation IDs belong to this
      # Pipeline rather than to the generic FSMSession.
      def handle_fsm_event(event)
        case event.type
        when :draft_completed
          return :consume unless event.payload[:request_id] == draft_request_id

          self.draft = event.payload[:draft]
          self.self_score = event.payload[:self_score]
          self.citations = event.payload[:citations]
          self.iteration = iteration + 1
          self.draft_request_id = nil
          self.pipeline_error = nil
        when :review_completed
          return :consume unless event.payload[:request_id] == review_request_id

          self.review_score = event.payload[:review_score]
          self.approved = event.payload[:approved]
          self.review_notes = review_notes + [event.payload[:feedback]]
          self.review_request_id = nil
          self.pipeline_error = nil
        when :draft_failed
          return :consume unless event.payload[:request_id] == draft_request_id

          self.pipeline_error = event.payload[:error]
          self.draft_request_id = nil
        when :review_failed
          return :consume unless event.payload[:request_id] == review_request_id

          self.pipeline_error = event.payload[:error]
          self.review_request_id = nil
        end
        false
      end
    end

    private_constant :PipelineState

    def initialize(
      draft_agent:,
      review_agent:,
      draft_prompt_builder:,
      review_prompt_builder:,
      draft_result_parser: nil,
      review_result_parser: nil,
      confidence_threshold: DEFAULT_CONFIDENCE_THRESHOLD,
      max_iterations: DEFAULT_MAX_ITERATIONS,
      raise_if_untrusted: false
    )
      @draft_agent_class = draft_agent
      @review_agent_class = review_agent
      @draft_prompt_builder = draft_prompt_builder
      @review_prompt_builder = review_prompt_builder
      @draft_result_parser =
        draft_result_parser || method(:default_parse_draft)
      @review_result_parser =
        review_result_parser || method(:default_parse_review)
      @threshold = confidence_threshold.to_f
      @max_iterations = max_iterations.to_i
      @raise_if_untrusted = raise_if_untrusted
      @compiled_workflow = nil
    end

    def invoke(input, config: {})
      state = compiled_workflow.invoke({input: input}, config: config)
      confidence = combined_confidence(state)
      trusted = confidence >= @threshold
      result = Result.new(
        output: state.output || state.draft.to_s,
        confidence: confidence,
        citations: state.citations,
        iterations: state.iteration,
        review_notes: state.review_notes,
        trusted: trusted
      )
      if @raise_if_untrusted && !trusted
        raise LowConfidenceError.new(result)
      end
      result
    end

    private

    def combined_confidence(state)
      [
        (state.self_score || 0.0).to_f,
        (state.review_score || 0.0).to_f
      ].min
    end

    def compiled_workflow
      @compiled_workflow ||= build_workflow
    end

    def build_workflow
      draft_agent = @draft_agent_class.new
      review_agent = @review_agent_class.new
      threshold = @threshold
      max_iterations = @max_iterations
      draft_prompt_builder = @draft_prompt_builder
      review_prompt_builder = @review_prompt_builder
      draft_result_parser = @draft_result_parser
      review_result_parser = @review_result_parser
      pipeline = self
      workflow = nil

      # workflow is assigned after define so closures captured by reference see the result.
      workflow = Phronomy::Workflow.define(PipelineState) do
        initial :draft

        state :draft
        state :review
        state :finalize
        state :failed

        entry :draft, ->(state) {
          request_id = SecureRandom.uuid
          next_state = state.merge(draft_request_id: request_id)
          feedback = next_state.review_notes.last
          prompt = draft_prompt_builder.call(next_state.input, feedback)

          draft_agent.invoke_async(
            prompt,
            on_event: ->(agent_event) {
              case agent_event.type
              when :done
                begin
                  parsed = draft_result_parser.call(
                    agent_event.payload[:output]
                  )
                  workflow.signal(
                    workflow_instance_id: next_state.workflow_instance_id,
                    event: :draft_completed,
                    payload: {
                      request_id: request_id,
                      draft: parsed[:answer].to_s,
                      self_score: pipeline.__send__(
                        :clamp,
                        parsed[:confidence]
                      ),
                      citations: pipeline.__send__(
                        :normalize_citations,
                        parsed[:citations]
                      )
                    }
                  )
                rescue => error
                  workflow.signal(
                    workflow_instance_id: next_state.workflow_instance_id,
                    event: :draft_failed,
                    payload: {
                      request_id: request_id,
                      error: error
                    }
                  )
                end
              when :error, :timeout, :cancelled
                workflow.signal(
                  workflow_instance_id: next_state.workflow_instance_id,
                  event: :draft_failed,
                  payload: {
                    request_id: request_id,
                    error:
                      agent_event.payload[:error] ||
                      Phronomy::Error.new(
                        "Draft Agent ended with #{agent_event.type}"
                      )
                  }
                )
              when :approval_required
                workflow.signal(
                  workflow_instance_id: next_state.workflow_instance_id,
                  event: :draft_failed,
                  payload: {
                    request_id: request_id,
                    error: Phronomy::Error.new(
                      "GeneratorVerifier draft Agent suspended for approval"
                    )
                  }
                )
              end
            }
          )

          next_state
        }

        entry :review, ->(state) {
          request_id = SecureRandom.uuid
          next_state = state.merge(review_request_id: request_id)
          prompt = review_prompt_builder.call(
            next_state.input,
            next_state.draft,
            next_state.citations
          )

          review_agent.invoke_async(
            prompt,
            on_event: ->(agent_event) {
              case agent_event.type
              when :done
                begin
                  parsed = review_result_parser.call(
                    agent_event.payload[:output]
                  )
                  workflow.signal(
                    workflow_instance_id: next_state.workflow_instance_id,
                    event: :review_completed,
                    payload: {
                      request_id: request_id,
                      review_score: pipeline.__send__(
                        :clamp,
                        parsed[:score]
                      ),
                      approved: parsed[:approved] == true,
                      feedback: parsed[:feedback].to_s
                    }
                  )
                rescue => error
                  workflow.signal(
                    workflow_instance_id: next_state.workflow_instance_id,
                    event: :review_failed,
                    payload: {
                      request_id: request_id,
                      error: error
                    }
                  )
                end
              when :error, :timeout, :cancelled
                workflow.signal(
                  workflow_instance_id: next_state.workflow_instance_id,
                  event: :review_failed,
                  payload: {
                    request_id: request_id,
                    error:
                      agent_event.payload[:error] ||
                      Phronomy::Error.new(
                        "Review Agent ended with #{agent_event.type}"
                      )
                  }
                )
              when :approval_required
                workflow.signal(
                  workflow_instance_id: next_state.workflow_instance_id,
                  event: :review_failed,
                  payload: {
                    request_id: request_id,
                    error: Phronomy::Error.new(
                      "GeneratorVerifier review Agent suspended for approval"
                    )
                  }
                )
              end
            }
          )

          next_state
        }

        entry :finalize, ->(state) {
          state.output = state.draft
          state
        }

        entry :failed, ->(state) {
          raise(
            state.pipeline_error ||
            Phronomy::Error.new("GeneratorVerifier Agent operation failed")
          )
        }

        transition from: :draft, on: :draft_completed, to: :review
        transition from: :draft, on: :draft_failed, to: :failed

        transition from: :review,
          on: :review_completed,
          guard: ->(state) {
            confidence = [
              state.self_score || 0.0,
              state.review_score || 0.0
            ].min
            (confidence >= threshold && state.approved) ||
              state.iteration >= max_iterations
          },
          to: :finalize
        transition from: :review,
          on: :review_completed,
          to: :draft
        transition from: :review,
          on: :review_failed,
          to: :failed

        transition from: :finalize, to: :__finish__
      end
    end

    def default_parse_draft(text)
      json_parser.parse(text)
    rescue Phronomy::ParseError
      {
        answer: text.to_s,
        confidence: 0.0,
        citations: []
      }
    end

    def default_parse_review(text)
      json_parser.parse(text)
    rescue Phronomy::ParseError
      {
        approved: false,
        score: 0.0,
        feedback: "Review output could not be parsed: #{text}"
      }
    end

    def json_parser
      @json_parser ||= Phronomy::OutputParser::JsonParser.new
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
