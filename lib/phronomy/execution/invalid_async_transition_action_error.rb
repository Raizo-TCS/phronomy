# frozen_string_literal: true

require_relative "invalid_async_workflow_action_error"

module Phronomy
  # Raised when a synchronous Workflow transition action returns Phronomy::TaskResult.
  #
  # Transition actions are Run-to-Completion callbacks. They may start
  # asynchronous work, but completion must return through a later explicit event.
  class InvalidAsyncTransitionActionError <
    InvalidAsyncWorkflowActionError
  end
end
