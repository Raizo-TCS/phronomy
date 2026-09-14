# frozen_string_literal: true

module Phronomy
  # Raised when a synchronous Workflow transition action returns Phronomy::TaskResult.
  #
  # Transition actions are Run-to-Completion callbacks. They may start
  # asynchronous work, but completion must return through a later explicit event.
  class InvalidAsyncTransitionActionError <
    InvalidAsyncWorkflowActionError
  end
end
