# frozen_string_literal: true

module Phronomy
  module Agent
    # Immutable event emitted by Agent async APIs.
    #
    # invoke_async and stream_async share lifecycle and Tool events. Streaming
    # additionally emits :token events.
    #
    # Common event types:
    #   :tool_call
    #   :tool_result
    #   :approval_required
    #   :done
    #   :error
    #   :timeout
    #   :cancelled
    #
    # Streaming-only event type:
    #   :token
    StreamEvent = Data.define(:type, :payload)
  end
end

require_relative "agent/async_event_api"

unless Phronomy::Agent::Base < Phronomy::Agent::AsyncEventApi
  Phronomy::Agent::Base.prepend(Phronomy::Agent::AsyncEventApi)
end
