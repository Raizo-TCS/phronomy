# frozen_string_literal: true

module Phronomy
  module Agent
    # Encapsulates the core per-invocation LLM round-trip for {Agent::Base}.
    #
    # {Agent::Base#invoke_once} delegates the body of each LLM turn to this
    # class, keeping the caller to a thin setup + trace frame (span≈2).
    # The pipeline executes inside the agent's binding via +instance_exec+
    # so that private concern methods (guardrails, hooks, cancellation) remain
    # encapsulated in their original modules while the orchestration logic lives
    # here.
    #
    # @api private
    class InvocationPipeline
      # @param agent [Agent::Base] the agent instance driving this invocation
      # @api private
      def initialize(agent)
        @agent = agent
      end

      # Runs one LLM round-trip inside the agent's execution context.
      #
      # Calls private {Agent::Base} concern methods (guardrails, hooks,
      # cancellation) via +instance_exec+ so that their encapsulation is
      # preserved, then routes the LLM request through the configured adapter.
      #
      # @param input      [String, Hash] the user input for this turn
      # @param messages   [Array]        prior conversation messages
      # @param thread_id  [String, nil]  persistence thread identifier
      # @param config     [Hash]         per-invocation options
      # @return [Array(Hash, Phronomy::TokenUsage, nil)]
      #   A two-element array: the result hash and the token usage (or nil on
      #   suspension).
      # @api private
      def run(input, messages:, thread_id:, config:)
        @agent.instance_exec(input, messages, thread_id, config) do |inp, msgs, tid, cfg|
          # Run input guardrails before touching the LLM.
          run_input_guardrails!(inp)

          user_message = extract_message(inp)
          chat = build_chat

          # Assemble context (system prompt + history). Override #build_context to
          # inject custom context editing logic at the Agent subclass level.
          context = build_context(inp, messages: msgs, thread_id: tid, config: cfg)
          apply_instructions(chat, context[:system]) if context[:system]
          (context[:tool_classes] || []).each { |tc| chat.with_tool(prepare_tool_class(tc)) }
          context[:messages].each { |msg| chat.messages << msg }

          # Run before_completion hooks (global → class → instance) before the LLM call.
          run_before_completion_hooks!(chat, cfg)

          # Register suspension hook for approval-required tools (no-op when a
          # synchronous on_approval_required handler is already registered).
          _register_suspension_hook!(chat)

          # Check for cancellation immediately before the LLM call.
          check_cancellation!(cfg, "invocation cancelled before LLM call")

          # Forward the cancellation token to ParallelToolChat explicitly
          # via the chat instance so that tool dispatch batches can observe
          # cancellation without needing Thread.current.
          chat.cancellation_token = cfg[:cancellation_token] if chat.respond_to?(:cancellation_token=)

          begin
            # Route the LLM call through the configured LLMAdapter so that the
            # blocking HTTP request runs inside BlockingAdapterPool and the
            # adapter can be swapped without changing agent code.
            adapter = Phronomy.configuration.llm_adapter
            response = adapter.complete_async(chat, user_message, config: cfg).await
          rescue SuspendSignal => signal
            checkpoint = Checkpoint.new(
              thread_id: tid,
              original_input: inp,
              messages: chat.messages.dup,
              pending_tool_name: signal.tool_name,
              pending_tool_args: signal.args,
              pending_tool_call_id: signal.tool_call_id
            )
            suspended_result = {output: nil, suspended: true, checkpoint: checkpoint, messages: chat.messages}
            next [suspended_result, nil]
          ensure
            # Clear the chat's cancellation token reference after each LLM call.
            chat.cancellation_token = nil if chat.respond_to?(:cancellation_token=)
          end

          output = response.content
          usage = Phronomy::TokenUsage.from_tokens(response.tokens)

          # Run output guardrails before returning to the caller.
          run_output_guardrails!(output)

          result = {output: output, messages: chat.messages, usage: usage}
          [result, usage]
        end
      end
    end
  end
end
