# frozen_string_literal: true

require_relative "invalid_async_workflow_action_error"

module Phronomy
  # Raised when a synchronous FSM entry action returns Phronomy::TaskResult.
  #
  # Entry actions are Run-to-Completion callbacks. They may start asynchronous
  # work, but completion must return through a later explicit event.
  class InvalidAsyncEntryActionError < InvalidAsyncWorkflowActionError; end
end
