# frozen_string_literal: true

module Phronomy
  module MultiAgent
    # RubyLLM::Chat subclass supporting concurrent direct Tool execution.
    #
    # AgentInvocation installs +on_tool_call_batch+ and intercepts the whole batch
    # before this class dispatches anything. The existing direct-chat fallback is
    # retained for callers that use ParallelToolChat outside Agent::Base.
    # @api private
    class ParallelToolChat < RubyLLM::Chat
      def initialize(max_parallel_tools: 10, cancellation_token: nil, **opts)
        super(**opts)
        @max_parallel_tools = max_parallel_tools
        @cancellation_token = cancellation_token
      end

      attr_writer :cancellation_token

      # Registers an Agent-owned batch interceptor. The callback must return
      # quickly or raise ToolCallIntercepted; it must not execute Tool bodies.
      def on_tool_call_batch(&block)
        @on[:tool_call_batch] = block
        self
      end

      private

      def handle_tool_calls(response, &block)
        tool_calls = response.tool_calls.values
        return super if tool_calls.size <= 1

        if @on[:tool_call_batch]
          tool_calls.each { @on[:new_message]&.call }
          @on[:tool_call_batch].call(tool_calls)
          return
        end

        # Direct ParallelToolChat fallback. Agent execution never reaches this
        # branch because AgentInvocation installs the batch interceptor first.
        tool_calls.each do |tool_call|
          @on[:new_message]&.call
          @on[:tool_call]&.call(tool_call)
        end

        cancellation_token = @cancellation_token
        max = @max_parallel_tools
        tool_results = tool_calls.each_slice(max).flat_map do |batch|
          if cancellation_token&.cancelled?
            raise Phronomy::CancellationError,
              "invocation cancelled before tool execution"
          end

          dispatched = batch.map do |tool_call|
            tool = tools[tool_call.name.to_sym]
            unless tool
              next {
                tool_call: tool_call,
                awaitable: nil,
                result: {
                  error: "Model tried to call unavailable tool `#{tool_call.name}`. " \
                    "Available tools: #{tools.keys.to_json}."
                }
              }
            end

            awaitable = Phronomy::Agent::ToolExecutor.call_async(
              tool: tool,
              args: tool_call.arguments,
              cancellation_token: cancellation_token
            )
            {tool_call: tool_call, awaitable: awaitable, result: nil}
          end

          dispatched.map do |item|
            result = item[:awaitable] ? item[:awaitable].wait_result : item[:result]
            {tool_call: item[:tool_call], result: result}
          end
        end

        halt_result = nil
        tool_results.each do |item|
          result = item[:result]
          @on[:tool_result]&.call(result)
          tool_payload = result.is_a?(RubyLLM::Tool::Halt) ? result.content : result
          content = content_like?(tool_payload) ? tool_payload : tool_payload.to_s
          message = add_message(
            role: :tool,
            content: content,
            tool_call_id: item[:tool_call].id
          )
          @on[:end_message]&.call(message)
          halt_result = result if result.is_a?(RubyLLM::Tool::Halt)
        end

        reset_tool_choice if forced_tool_choice?
        halt_result || complete(&block)
      end

      def execute_tool(tool_call)
        tool = tools[tool_call.name.to_sym]
        unless tool
          return {
            error: "Model tried to call unavailable tool `#{tool_call.name}`. " \
              "Available tools: #{tools.keys.to_json}."
          }
        end

        Phronomy::Agent::ToolExecutor.call_async(
          tool: tool,
          args: tool_call.arguments,
          cancellation_token: @cancellation_token
        ).wait_result
      end
    end
  end
end
