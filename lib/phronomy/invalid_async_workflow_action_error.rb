# frozen_string_literal: true

module Phronomy
  # Base error for synchronous Workflow callbacks that return Phronomy::Task.
  #
  # Workflow callbacks may start asynchronous work, but they must return
  # synchronously and deliver completion through a later explicit event.
  class InvalidAsyncWorkflowActionError < Error; end
end
