# frozen_string_literal: true

module Phronomy
  class GeneratorVerifier
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
  end
end
