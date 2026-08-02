# frozen_string_literal: true

module Phronomy
  # Raised when a synchronous FSM entry action returns Phronomy::Task.
  #
  # Entry actions are Run-to-Completion callbacks. They may start asynchronous
  # work, but completion must return through a later explicit event.
  class InvalidAsyncEntryActionError < InvalidAsyncWorkflowActionError; end
end
