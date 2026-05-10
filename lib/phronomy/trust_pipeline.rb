# frozen_string_literal: true

module Phronomy
  # Orchestrates three trust mechanisms in a single pipeline:
  #
  # 1. **Citation Tracking** — the DraftAgent is prompted to list the knowledge
  #    sources it relied on. Citations are extracted and attached to the result.
  #
  # 2. **Self-Review Loop** — a dedicated ReviewAgent evaluates each draft,
  #    assigns a quality score, and provides actionable feedback. Rejected drafts
  #    are retried with the reviewer's feedback embedded in the next prompt.
  #
  # 3. **Confidence Gate** — a combined confidence score (the minimum of the
  #    DraftAgent's self-reported confidence and the ReviewAgent's score) is
  #    compared against a threshold. The pipeline finishes early when the gate
  #    passes; after +max_iterations+ cycles it finishes regardless and marks
  #    the result as untrusted when the threshold was not reached.
  #
  # @example
  #   pipeline = Phronomy::TrustPipeline.new(
  #     draft_agent:          PolicyDraftAgent,
  #     review_agent:         PolicyReviewAgent,
  #     confidence_threshold: 0.7,
  #     max_iterations:       3
  #   )
  #   result = pipeline.invoke("What is the refund policy?")
  #   puts result.output      # the final answer string
  #   puts result.trusted?    # true when confidence >= threshold
  #   result.citations.each { |c| puts "#{c[:source]}: #{c[:excerpt]}" }
  class TrustPipeline
    # Default confidence threshold for trusting an answer.
    DEFAULT_CONFIDENCE_THRESHOLD = 0.7

    # Default maximum draft-review cycles before returning best effort.
    DEFAULT_MAX_ITERATIONS = 3

    # Immutable value object returned by {TrustPipeline#invoke}.
    #
    # @!attribute [r] output
    #   @return [String] the final answer text
    # @!attribute [r] confidence
    #   @return [Float] combined confidence score (0.0–1.0)
    # @!attribute [r] citations
    #   @return [Array<Hash>] [{source:, excerpt:}, ...]
    # @!attribute [r] iterations
    #   @return [Integer] number of draft-review cycles executed
    # @!attribute [r] review_notes
    #   @return [Array<String>] reviewer feedback for each cycle
    # @!attribute [r] trusted
    #   @return [Boolean] true when confidence >= threshold
    Result = Struct.new(:output, :confidence, :citations, :iterations, :review_notes, :trusted, keyword_init: true) do
      # @return [Boolean] true when confidence >= threshold
      alias_method :trusted?, :trusted
    end

    # Internal graph state — not part of the public API.
    # @private
    class PipelineState
      include Phronomy::Graph::State

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

    # @param draft_agent          [Class]   subclass of Phronomy::Agent::Base
    # @param review_agent         [Class]   subclass of Phronomy::Agent::Base
    # @param confidence_threshold [Float]   answers below this are retried (default: 0.7)
    # @param max_iterations       [Integer] maximum draft-review cycles (default: 3)
    def initialize(draft_agent:, review_agent:,
      confidence_threshold: DEFAULT_CONFIDENCE_THRESHOLD,
      max_iterations: DEFAULT_MAX_ITERATIONS)
      @draft_agent_class = draft_agent
      @review_agent_class = review_agent
      @threshold = confidence_threshold.to_f
      @max_iterations = max_iterations.to_i
      @graph_mutex = Mutex.new
      @compiled_graph = nil
    end

    # Run the pipeline.
    #
    # @param input  [String] the user question or task description
    # @param config [Hash]   forwarded to the underlying agents (e.g. thread_id)
    # @return [Result]
    def invoke(input, config: {})
      app = compiled_graph
      state = app.invoke({input: input}, config: config)
      confidence = combined_confidence(state)
      Result.new(
        output: state.output || state.draft.to_s,
        confidence: confidence,
        citations: state.citations,
        iterations: state.iteration,
        review_notes: state.review_notes,
        trusted: confidence >= @threshold
      )
    end

    private

    def combined_confidence(state)
      [(state.self_score || 0.0).to_f, (state.review_score || 0.0).to_f].min
    end

    # Returns the compiled graph, building and caching it on first call.
    # Thread-safe via double-checked locking.
    def compiled_graph
      return @compiled_graph if @compiled_graph

      @graph_mutex.synchronize do
        @compiled_graph ||= build_graph.compile
      end
    end

    def build_graph
      draft_agent = @draft_agent_class.new
      review_agent = @review_agent_class.new
      threshold = @threshold
      max_iter = @max_iterations

      graph = Phronomy::Graph::StateGraph.new(PipelineState)

      graph.add_node(:draft) do |state|
        feedback = state.review_notes.last
        prompt = draft_prompt(state.input, feedback)
        result = draft_agent.invoke(prompt)
        parsed = safe_parse_draft(result[:output])
        state.merge(
          draft: parsed[:answer].to_s,
          self_score: clamp(parsed[:confidence]),
          citations: normalize_citations(parsed[:citations]),
          iteration: state.iteration + 1
        )
      end

      graph.add_node(:review) do |state|
        prompt = review_prompt(state.input, state.draft, state.citations)
        result = review_agent.invoke(prompt)
        parsed = safe_parse_review(result[:output])
        state.merge(
          review_score: clamp(parsed[:score]),
          approved: parsed[:approved] == true,
          review_notes: parsed[:feedback].to_s
        )
      end

      graph.add_node(:finalize) do |state|
        state.merge(output: state.draft)
      end

      graph.set_entry_point(:draft)
      graph.add_edge(:draft, :review)
      graph.add_conditional_edges(
        :review,
        ->(state) {
          confidence = [state.self_score || 0.0, state.review_score || 0.0].min
          passed = confidence >= threshold && state.approved
          exhausted = state.iteration >= max_iter
          (passed || exhausted) ? :finalize : :draft
        }
      )
      graph.add_edge(:finalize, Phronomy::Graph::StateGraph::FINISH)

      graph
    end

    # Builds the prompt sent to the DraftAgent for each iteration.
    def draft_prompt(input, feedback)
      lines = [
        "Answer the following question as accurately as possible.",
        "Use any knowledge provided in <context> tags and cite your sources."
      ]
      if feedback && !feedback.strip.empty?
        lines << ""
        lines << "Your previous draft was reviewed and rejected. Address ALL of this feedback:"
        lines << feedback.strip
      end
      lines += [
        "",
        "Question: #{input}",
        "",
        "RESPOND ONLY WITH VALID JSON (no text outside the JSON block):",
        '{"answer":"<full answer>","confidence":<0.0-1.0>,' \
          '"citations":[{"source":"<doc name>","excerpt":"<exact quote>"}]}'
      ]
      lines.join("\n")
    end

    # Builds the prompt sent to the ReviewAgent.
    def review_prompt(input, draft, citations)
      citation_text = if citations.empty?
        "  (none)"
      else
        citations.map { |c| "  - #{c[:source]}: \"#{c[:excerpt]}\"" }.join("\n")
      end
      [
        "You are a rigorous quality reviewer. Evaluate the draft answer below.",
        "",
        "Question: #{input}",
        "",
        "Draft answer:",
        draft.to_s,
        "",
        "Citations provided:",
        citation_text,
        "",
        "Evaluation criteria:",
        "  1. Is the answer factually accurate and complete?",
        "  2. Is every significant claim backed by a citation?",
        "  3. Is the self-reported confidence realistic?",
        "",
        "RESPOND ONLY WITH VALID JSON (no text outside the JSON block):",
        '{"approved":<true|false>,"score":<0.0-1.0>,' \
          '"feedback":"<specific actionable feedback, or empty string if approved>"}'
      ].join("\n")
    end

    def safe_parse_draft(text)
      json_parser.parse(text)
    rescue Phronomy::ParseError
      {answer: text.to_s, confidence: 0.0, citations: []}
    end

    def safe_parse_review(text)
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
