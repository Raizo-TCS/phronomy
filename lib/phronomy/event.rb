# frozen_string_literal: true

module Phronomy
  # Immutable event struct used for inter-FSM communication via EventLoop.
  #
  # @param type      [Symbol]  event identifier (:start, :state_completed,
  #                            :finished, :halted, :error, or any user-defined name)
  # @param target_id [String]  FSMSession identifier — matches WorkflowContext#thread_id
  # @param payload   [Object]  optional data attached to the event:
  #                            - final/halted context for :finished/:halted
  #                            - Exception for :error
  #                            - nil for :start / :state_completed
  Event = Data.define(:type, :target_id, :payload)
end
