# frozen_string_literal: true

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

    private_constant :PipelineState, :WorkflowBuilder, :AgentResultReceiver

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
      WorkflowBuilder.new(
        draft_agent: @draft_agent_class.new,
        review_agent: @review_agent_class.new,
        draft_prompt_builder: @draft_prompt_builder,
        review_prompt_builder: @review_prompt_builder,
        draft_result_parser: @draft_result_parser,
        review_result_parser: @review_result_parser,
        threshold: @threshold,
        max_iterations: @max_iterations
      ).build
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
  end
end
