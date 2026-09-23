# frozen_string_literal: true

require_relative "../common/error"

module Phronomy
  # Base error for synchronous Workflow callbacks that return Phronomy::TaskResult.
  #
  # Workflow callbacks may start asynchronous work, but they must return
  # synchronously and deliver completion through a later explicit event.
  class InvalidAsyncWorkflowActionError < Error; end
end
