# frozen_string_literal: true

require_relative "../../common/error"

module Phronomy
  # A live task wait cannot be reconstructed from a Workflow state snapshot.
  # @api public
  class WorkflowTaskResumeError < Error
    # @api public
    def initialize(message = "Cannot resume a pending Workflow task_state; explicit reconciliation is required", code: "workflow.task_resume_unsupported")
      super
    end
  end
end
