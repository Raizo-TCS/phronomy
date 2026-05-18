# frozen_string_literal: true

module Phronomy
  # @deprecated Use {Phronomy::GeneratorVerifier} with explicit prompt builders instead.
  #
  # TrustPipeline is kept for backward compatibility only. It wraps
  # {GeneratorVerifier} with fixed default prompts and will be removed in a
  # future release.
  #
  # Migration guide:
  #   # Before:
  #   pipeline = Phronomy::TrustPipeline.new(
  #     draft_agent: MyDraftAgent,
  #     review_agent: MyReviewAgent
  #   )
  #
  #   # After:
  #   pipeline = Phronomy::GeneratorVerifier.new(
  #     draft_agent:           MyDraftAgent,
  #     review_agent:          MyReviewAgent,
  #     draft_prompt_builder:  ->(input, feedback) { "Question: #{input}" },
  #     review_prompt_builder: ->(input, draft, citations) { "Review: #{draft}" }
  #   )
  class TrustPipeline < GeneratorVerifier
    # Backward-compatible alias for {Phronomy::GeneratorVerifier::Result}.
    # @deprecated Use {Phronomy::GeneratorVerifier::Result} instead.
    Result = GeneratorVerifier::Result

    # @param draft_agent          [Class]   subclass of Phronomy::Agent::Base
    # @param review_agent         [Class]   subclass of Phronomy::Agent::Base
    # @param confidence_threshold [Float]   (default: 0.7)
    # @param max_iterations       [Integer] (default: 3)
    # @param input_delimiter      [Array<String>, nil] optional [start_tag, end_tag]
    #   pair used to wrap user input in prompts
    # @param kwargs [Hash] additional options forwarded to {GeneratorVerifier}
    #   (e.g. +raise_if_untrusted: true+)
    def initialize(
      draft_agent:,
      review_agent:,
      confidence_threshold: DEFAULT_CONFIDENCE_THRESHOLD,
      max_iterations: DEFAULT_MAX_ITERATIONS,
      input_delimiter: nil,
      **kwargs
    )
      warn "[DEPRECATION] Phronomy::TrustPipeline is deprecated. " \
           "Use Phronomy::GeneratorVerifier with explicit prompt builders instead."
      super(
        draft_agent: draft_agent,
        review_agent: review_agent,
        draft_prompt_builder: build_draft_prompt_builder(input_delimiter),
        review_prompt_builder: build_review_prompt_builder(input_delimiter),
        confidence_threshold: confidence_threshold,
        max_iterations: max_iterations,
        **kwargs
      )
    end

    private

    def build_draft_prompt_builder(input_delimiter)
      ->(input, feedback) {
        wrapped = wrap_with_delimiter(input, input_delimiter)
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
          "Question: #{wrapped}",
          "",
          "RESPOND ONLY WITH VALID JSON (no text outside the JSON block):",
          '{"answer":"<full answer>","confidence":<0.0-1.0>,' \
            '"citations":[{"source":"<doc name>","excerpt":"<exact quote>"}]}'
        ]
        lines.join("\n")
      }
    end

    def build_review_prompt_builder(input_delimiter)
      ->(input, draft, citations) {
        wrapped = wrap_with_delimiter(input, input_delimiter)
        citation_text = if citations.empty?
          "  (none)"
        else
          citations.map { |c| "  - #{c[:source]}: \"#{c[:excerpt]}\"" }.join("\n")
        end
        [
          "You are a rigorous quality reviewer. Evaluate the draft answer below.",
          "",
          "Question: #{wrapped}",
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
      }
    end

    def wrap_with_delimiter(input, delimiter)
      return input unless delimiter

      start_tag, end_tag = delimiter
      "#{start_tag}\n#{input}\n#{end_tag}"
    end
  end
end
