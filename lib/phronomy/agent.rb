# frozen_string_literal: true

module Phronomy
  module Agent
    # Represents a single event emitted during a streaming agent invocation.
    #
    # type values:
    #   :token       — a content delta from the LLM (payload: { content: String })
    #   :tool_call   — the LLM requested a tool call (payload: { tool_call: Object })
    #   :tool_result — a tool finished executing (payload: { tool_call_id: String, tool_name: String,
    #                                                         tool_result: Object })
    #   :done        — the agent finished (payload: { output: String, messages: Array,
    #                                                  usage: TokenUsage })
    #   :error       — an unrecoverable error occurred (payload: { error: Exception })
    StreamEvent = Data.define(:type, :payload)
  end
end
