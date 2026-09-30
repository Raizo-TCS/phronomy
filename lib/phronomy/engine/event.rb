# frozen_string_literal: true

module Phronomy
  # Immutable event used for EventLoop communication.
  #
  # User-defined Workflow events carry application-owned payloads unchanged.
  # Correlation identifiers, stale-event decisions, and domain interpretation
  # remain application concerns.
  #
  # @param type      [Symbol] event identifier
  # @param target_id [String] FSMSession identifier
  # @param payload   [Object] optional event data
  Event = Data.define(:type, :target_id, :payload)
end
