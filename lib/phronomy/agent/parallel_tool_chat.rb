# frozen_string_literal: true

module Phronomy
  module Agent
    # RubyLLM::Chat subclass that executes multiple tool calls concurrently.
    #
    # When the LLM returns more than one tool call in a single response, each
    # tool is dispatched according to its +execution_mode+:
    # - +:cooperative+ tools run via +Runtime.instance.spawn+ on the
    #   cooperative scheduler (non-preemptive, no extra OS thread).
    # - +:blocking_io+ tools are offloaded to a +BlockingAdapterPool+ worker
    #   thread so they do not occupy a scheduler task slot.
    # All results are collected before being appended to the message history,
    # preserving deterministic message order while reducing wall-clock latency
    # when tools are IO-bound (HTTP calls, DB queries, etc.).
    #
    # Single-tool responses fall through to the standard sequential path via
    # +super+, preserving all existing edge-case behaviour (Tool::Halt,
    # forced_tool_choice, streaming, SuspendSignal, etc.).
    #
    # This class is used automatically when EventLoop mode is enabled
    # ({Phronomy.configuration.event_loop}).  It is not used for direct
    # synchronous +invoke+ calls so that the streaming callback state remains
    # single-threaded.
    # @api private
    class ParallelToolChat < RubyLLM::Chat
      # @param max_parallel_tools [Integer] maximum simultaneous tool executions
      # @param cancellation_token [Phronomy::CancellationToken, nil] token observed before each batch
      # @param opts [Hash] remaining kwargs forwarded to RubyLLM::Chat
      # @api private
      def initialize(max_parallel_tools: 10, cancellation_token: nil, **opts)
        super(**opts)
        @max_parallel_tools = max_parallel_tools
        @cancellation_token = cancellation_token
      end

      # Allows the owning agent to update the token between retries.
      # @api private
      attr_writer :cancellation_token

      private

      # Overrides RubyLLM::Chat#handle_tool_calls to parallelise execution
      # when multiple tool calls are present in a single LLM response.
      #
      # The method preserves the three-phase protocol of the original:
      #   1. Pre-execution callbacks (+on_new_message+, +on_tool_call+) —
      #      sequential so that the Suspendable concern's approval hook can
      #      raise +SuspendSignal+ before any tool is executed.
      #   2. Parallel tool execution — cooperative tools via Runtime.instance.spawn,
      #      blocking_io tools via BlockingAdapterPool.
      #   3. Post-execution callbacks and message recording — sequential,
      #      in the original tool-call order.
      #
      # @param response [RubyLLM::Message] the LLM response containing tool calls
      # @yield streaming block forwarded to +complete+
      # @api private
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
        # :cooperative tools run inside a Task (no pool).
        # :blocking_io/:cpu_bound/:external_process tools are submitted directly
        # to BlockingAdapterPool when available — eliminating the extra Task
        # Thread that previously wrapped each pool operation.
        #
        # Both Phronomy::Task and BlockingAdapterPool::PendingOperation support
        # #await, so results are collected uniformly below.
        ct = @cancellation_token
        max = @max_parallel_tools
        thread_results = tool_calls.each_slice(max).flat_map do |batch|
          if ct&.cancelled?
            raise Phronomy::CancellationError, "invocation cancelled before tool execution"
          end

          # Dispatch all tools in this batch via ToolExecutor (centralised routing).
          dispatched = batch.map do |tc|
            tool = tools[tc.name.to_sym]
            unless tool
              next {tool_call: tc, awaitable: nil, result: {
                error: "Model tried to call unavailable tool `#{tc.name}`. " \
                       "Available tools: #{tools.keys.to_json}."
              }}
            end

            awaitable = Phronomy::ToolExecutor.call_async(
              tool: tool,
              args: tc.arguments,
              cancellation_token: ct
            )
            {tool_call: tc, awaitable: awaitable, result: nil}
          end

          # Await all dispatched operations in original order.
          dispatched.map do |item|
            result = item[:awaitable] ? item[:awaitable].await : item[:result]
            {tool_call: item[:tool_call], result: result}
          end
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

      # Overrides RubyLLM::Chat#execute_tool to forward the cancellation token
      # explicitly so that Tool::Base#call does not need Thread.current.
      #
      # When the tool declares execution_mode :cooperative, the call is made
      # directly.  For :blocking_io (the default) the call is delegated to the
      # BlockingAdapterPool when a Runtime is available so that blocking
      # network / DB calls do not occupy a scheduler task slot.
      def execute_tool(tool_call)
        tool = tools[tool_call.name.to_sym]
        unless tool
          return {
            error: "Model tried to call unavailable tool `#{tool_call.name}`. " \
                   "Available tools: #{tools.keys.to_json}."
          }
        end

        mode = tool.class.execution_mode
        ct = @cancellation_token

        if mode == :cooperative
          tool.call(tool_call.arguments, cancellation_token: ct)
        else
          # :blocking_io (default), :cpu_bound, :external_process
          # Delegate to BlockingAdapterPool when a Runtime is available so that
          # blocking I/O does not occupy a scheduler task.
          pool = begin; Phronomy::Runtime.instance&.blocking_io; rescue; nil; end
          if pool
            op = pool.submit(cancellation_token: ct) do
              tool.call(tool_call.arguments, cancellation_token: ct)
            end
            op.await
          else
            # No pool configured — fall back to direct call (non-EventLoop mode).
            tool.call(tool_call.arguments, cancellation_token: ct)
          end
        end
      end
    end
  end
end
