# frozen_string_literal: true

module Phronomy
  module Agent
    # RubyLLM::Chat subclass that executes multiple tool calls concurrently.
    #
    # When the LLM returns more than one tool call in a single response, each
    # tool is dispatched in a dedicated IO thread and all results are collected
    # before being appended to the message history. This preserves a
    # deterministic message order while reducing wall-clock latency when tools
    # are IO-bound (HTTP calls, DB queries, etc.).
    #
    # Single-tool responses fall through to the standard sequential path via
    # +super+, preserving all existing edge-case behaviour (Tool::Halt,
    # forced_tool_choice, streaming, SuspendSignal, etc.).
    #
    # This class is used automatically when the agent is running inside an
    # {AgentFSM} IO thread (i.e. when the +:phronomy_agent_parallel_tools+
    # thread-local flag is +true+).  It is not used for direct synchronous
    # +invoke+ calls so that the streaming callback state remains single-threaded.
    class ParallelToolChat < RubyLLM::Chat
      private

      # Overrides RubyLLM::Chat#handle_tool_calls to parallelise execution
      # when multiple tool calls are present in a single LLM response.
      #
      # The method preserves the three-phase protocol of the original:
      #   1. Pre-execution callbacks (+on_new_message+, +on_tool_call+) —
      #      sequential so that the Suspendable concern's approval hook can
      #      raise +SuspendSignal+ before any tool is executed.
      #   2. Parallel tool execution — one IO thread per tool call.
      #   3. Post-execution callbacks and message recording — sequential,
      #      in the original tool-call order.
      #
      # @param response [RubyLLM::Message] the LLM response containing tool calls
      # @yield streaming block forwarded to +complete+
      def handle_tool_calls(response, &block)
        tool_calls = response.tool_calls.values

        # Single tool: delegate to the parent implementation to preserve every
        # edge case (forced_tool_choice, streaming, Halt, SuspendSignal…).
        return super if tool_calls.size <= 1

        # Phase 1 — pre-execution callbacks (sequential, original order).
        # The SuspendSignal approval hook is registered via on_tool_call, so it
        # MUST fire before execution begins.
        tool_calls.each do |tool_call|
          @on[:new_message]&.call
          @on[:tool_call]&.call(tool_call)
        end

        # Phase 2 — parallel tool execution.
        # Honour the per-agent concurrency cap (max_parallel_tools DSL).
        # Tool calls are processed in batches of at most `max` threads;
        # batches run sequentially so the total in-flight thread count never
        # exceeds the limit.
        max = Thread.current[:phronomy_max_parallel_tools] || 10
        thread_results = tool_calls.each_slice(max).flat_map do |batch|
          threads = batch.map do |tool_call|
            Thread.new { {tool_call: tool_call, result: execute_tool(tool_call)} }
          end
          threads.map(&:value)
        end

        # Phase 3 — post-execution callbacks and message recording (sequential).
        halt_result = nil
        thread_results.each do |item|
          result = item[:result]
          @on[:tool_result]&.call(result)
          tool_payload = result.is_a?(RubyLLM::Tool::Halt) ? result.content : result
          content = content_like?(tool_payload) ? tool_payload : tool_payload.to_s
          message = add_message(role: :tool, content: content, tool_call_id: item[:tool_call].id)
          @on[:end_message]&.call(message)
          halt_result = result if result.is_a?(RubyLLM::Tool::Halt)
        end

        reset_tool_choice if forced_tool_choice?
        halt_result || complete(&block)
      end
    end
  end
end
