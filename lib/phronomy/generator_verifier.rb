# frozen_string_literal: true

module Phronomy
  # Implements the Generator-Verifier multi-agent coordination pattern
  # (Anthropic blog, Pattern 1): a generator agent produces an
  # answer while a verifier agent evaluates its quality.
  #
  # @see https://claude.com/blog/multi-agent-coordination-patterns
  #
  # All prompt construction and result parsing are provided by the caller,
  # giving full control over the LLM dialogue.
  # The generator and verifier agents are configurable, and the pipeline
  # retries until confidence passes the threshold or max iterations are reached.
  #
  # @example Basic usage with custom prompt builders
  #   pipeline = Phronomy::GeneratorVerifier.new(
  #     draft_agent:           MyDraftAgent,
  #     review_agent:          MyReviewAgent,
  #     draft_prompt_builder:  ->(input, feedback) { "Question: #{input}" },
  #     review_prompt_builder: ->(input, draft, citations) { "Review: #{draft}" }
  #   )
  #   result = pipeline.invoke("What is the refund policy?")
  #   puts result.output      # the final answer string
  #   puts result.trusted?    # true when confidence >= threshold
  #
  # @example Custom result parsers
  #   pipeline = Phronomy::GeneratorVerifier.new(
  #     ...,
  #     draft_result_parser:  ->(text) { my_parse_draft(text) },
  #     review_result_parser: ->(text) { my_parse_review(text) }
  #   )
  #
  # @example Raising on low confidence
  #   pipeline = Phronomy::GeneratorVerifier.new(
  #     ...,
  #     raise_if_untrusted: true
  #   )
  #   begin
  #     result = pipeline.invoke("question")
  #   rescue Phronomy::LowConfidenceError => e
  #     puts "Untrusted: #{e.result.confidence}"
  #   end
  class GeneratorVerifier
    # Default confidence threshold for trusting an answer.
    DEFAULT_CONFIDENCE_THRESHOLD = 0.7

    # Default maximum draft-review cycles before returning best effort.
    DEFAULT_MAX_ITERATIONS = 3

    # Immutable value object returned by {GeneratorVerifier#invoke}.
    #
    # @!attribute [r] output
    #   @return [String] the final answer text
    # @!attribute [r] confidence
    #   @return [Float] combined confidence score (0.0–1.0)
    # @!attribute [r] citations
    #   @return [Array<Hash>] [{source:, excerpt:}, ...]
    #
    #   **WARNING**: These citations are extracted from the LLM's own response
    #   and are **not** verified against any external knowledge base or URL.
    #   Do not treat them as authoritative without independent verification.
    # @!attribute [r] iterations
    #   @return [Integer] number of draft-review cycles executed
    # @!attribute [r] review_notes
    #   @return [Array<String>] reviewer feedback for each cycle
    # @!attribute [r] trusted
    #   @return [Boolean] true when confidence >= threshold
    Result = Struct.new(
      :output, :confidence, :citations, :iterations, :review_notes, :trusted,
      keyword_init: true
    ) do
      # @return [Boolean] true when confidence >= threshold
      alias_method :trusted?, :trusted
    end

    # Internal graph state — not part of the public API.
    # @private
    class PipelineState
      include Phronomy::WorkflowContext

      field :input, type: :replace, default: -> { "" }
      field :draft, type: :replace, default: -> {}
      field :self_score, type: :replace, default: -> { 0.0 }
      field :review_score, type: :replace, default: -> { 0.0 }
      field :citations, type: :replace, default: -> { [] }
      field :review_notes, type: :append, default: -> { [] }
      field :iteration, type: :replace, default: -> { 0 }
      field :approved, type: :replace, default: -> { false }
      field :output, type: :replace, default: -> {}
    end

    private_constant :PipelineState

    # @param draft_agent           [Class]   subclass of Phronomy::Agent::Base
    #   used to generate answer drafts
    # @param review_agent          [Class]   subclass of Phronomy::Agent::Base
    #   used to evaluate each draft
    # @param draft_prompt_builder  [#call]   +call(input, feedback)+ → String
    #   prompt for the generator. +feedback+ is nil on the first iteration and
    #   contains the reviewer's feedback string on subsequent iterations.
    # @param review_prompt_builder [#call]   +call(input, draft, citations)+ → String
    #   prompt for the verifier. +citations+ is an Array of Hashes.
    # @param draft_result_parser   [#call, nil]  +call(text)+ → Hash with
    #   +:answer+, +:confidence+, and +:citations+ keys. Defaults to JSON parsing
    #   with a safe fallback when the response cannot be parsed.
    # @param review_result_parser  [#call, nil]  +call(text)+ → Hash with
    #   +:approved+, +:score+, and +:feedback+ keys. Defaults to JSON parsing
    #   with a safe fallback.
    # @param confidence_threshold  [Float]   minimum combined confidence to
    #   trust an answer (default: 0.7)
    # @param max_iterations        [Integer] maximum draft-review cycles
    #   before returning the best-effort answer (default: 3)
    # @param raise_if_untrusted    [Boolean] when +true+, raises
    #   {Phronomy::LowConfidenceError} if the final result does not meet the
    #   confidence threshold (default: false)
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
      @draft_result_parser = draft_result_parser || method(:default_parse_draft)
      @review_result_parser = review_result_parser || method(:default_parse_review)
      @threshold = confidence_threshold.to_f
      @max_iterations = max_iterations.to_i
      @raise_if_untrusted = raise_if_untrusted
      @compiled_workflow = nil
    end

    # Run the generator-verifier pipeline.
    #
    # @param input  [String] the user question or task description
    # @param config [Hash]   forwarded to the underlying agents (e.g. thread_id)
    # @return [Result]
    # @raise [Phronomy::LowConfidenceError] when +raise_if_untrusted:+ is +true+
    #   and the result does not meet the confidence threshold
    def invoke(input, config: {})
      app = compiled_workflow
      state = app.invoke({input: input}, config: config)
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
      raise LowConfidenceError.new(result) if @raise_if_untrusted && !trusted
      result
    end

    private

    def combined_confidence(state)
      [(state.self_score || 0.0).to_f, (state.review_score || 0.0).to_f].min
    end

    def compiled_workflow
      @compiled_workflow ||= build_workflow
    end

    def build_workflow
      draft_agent = @draft_agent_class.new
      review_agent = @review_agent_class.new
      threshold = @threshold
      max_iter = @max_iterations
      dpb = @draft_prompt_builder
      rpb = @review_prompt_builder
      drp = @draft_result_parser
      rrp = @review_result_parser
      pipeline = self

      Phronomy::Workflow.define(PipelineState) do
        initial :draft

        state :draft
        state :review
        state :finalize

        entry :draft, ->(state) {
          feedback = state.review_notes.last
          prompt = dpb.call(state.input, feedback)
          result = draft_agent.invoke(prompt)
          parsed = drp.call(result[:output])
          state.draft = parsed[:answer].to_s
          state.self_score = pipeline.__send__(:clamp, parsed[:confidence])
          state.citations = pipeline.__send__(:normalize_citations, parsed[:citations])
          state.iteration = state.iteration + 1
        }

        entry :review, ->(state) {
          prompt = rpb.call(state.input, state.draft, state.citations)
          result = review_agent.invoke(prompt)
          parsed = rrp.call(result[:output])
          state.review_score = pipeline.__send__(:clamp, parsed[:score])
          state.approved = parsed[:approved] == true
          state.review_notes << parsed[:feedback].to_s
        }

        entry :finalize, ->(state) { state.output = state.draft }

        after :draft, to: :review
        after :finalize, to: :__finish__

        event :route_review, from: :review,
          guard: ->(state) {
            confidence = [state.self_score || 0.0, state.review_score || 0.0].min
            (confidence >= threshold && state.approved) || state.iteration >= max_iter
          },
          to: :finalize
        event :route_review, from: :review, to: :draft
      end
    end

    def default_parse_draft(text)
      json_parser.parse(text)
    rescue Phronomy::ParseError
      {answer: text.to_s, confidence: 0.0, citations: []}
    end

    def default_parse_review(text)
      json_parser.parse(text)
    rescue Phronomy::ParseError
      {approved: false, score: 0.0, feedback: "Review output could not be parsed: #{text}"}
    end

    def json_parser
      @json_parser ||= Phronomy::OutputParser::JsonParser.new
    end

    def clamp(val)
      val.to_f.clamp(0.0, 1.0)
    end

    def normalize_citations(raw)
      Array(raw).filter_map { |c| c.is_a?(Hash) ? c.transform_keys(&:to_sym) : nil }
    end
  end
end
