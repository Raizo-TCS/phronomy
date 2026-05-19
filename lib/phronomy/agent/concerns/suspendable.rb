# frozen_string_literal: true

module Phronomy
  module Agent
    module Concerns
      # Adds suspend/resume and tool-approval support to an agent.
      #
      # Included in {Phronomy::Agent::Base}. When a tool decorated with
      # +requires_approval true+ is called and no synchronous approval handler
      # has been registered, the invocation is suspended and a
      # {Phronomy::Agent::Checkpoint} is returned so the caller can resume later.
      module Suspendable
        # Registers a callback that is invoked before executing any tool that has
        # +requires_approval true+ set. The block receives the tool name (String)
        # and the arguments Hash, and must return a truthy value to allow execution.
        # Returning a falsy value causes the tool to return a denial message instead
        # of executing.
        #
        # When no handler is registered and a tool with +requires_approval+ is
        # called, #invoke returns a suspended result hash containing a
        # {Phronomy::Agent::Checkpoint}. Call #resume to continue execution after
        # obtaining an approval decision from the user or an external system.
        #
        # @example Synchronous handler
        #   agent = MyAgent.new
        #   agent.on_approval_required { |tool_name, args| prompt_user(tool_name, args) }
        # @return [self]
        def on_approval_required(&block)
          @approval_handler = block
          self
        end

        # Resumes a previously suspended invocation from a {Phronomy::Agent::Checkpoint}.
        #
        # This method reconstructs the conversation state captured at suspension
        # time, injects the tool result (executed or denied), and continues the
        # LLM loop until it produces a final answer.
        #
        # @param checkpoint [Phronomy::Agent::Checkpoint] the checkpoint returned by
        #   the suspended #invoke call
        # @param approved   [Boolean] +true+ to execute the pending tool; +false+
        #   to inject a denial message and let the LLM handle it gracefully
        # @param config     [Hash] same runtime options as #invoke
        # @return [Hash] +{ output: String, suspended: false, messages: Array, usage: Phronomy::TokenUsage }+
        # @raise [Phronomy::GuardrailError] when an output guardrail rejects the value
        def resume(checkpoint, approved:, config: {})
          # Build a fresh chat with all tools registered.
          chat = build_chat

          # Re-apply system instructions so the LLM has the same persona/context
          # as the original invocation. build_cached_system_text is memoised, so
          # a Proc- or PromptTemplate-based instructions block is re-evaluated
          # against the original input rather than using a stale cached value.
          system_text = build_cached_system_text(checkpoint.original_input)
          apply_instructions(chat, system_text) if system_text

          # Restore the full conversation (history + user + assistant with tool call).
          checkpoint.messages.each { |msg| chat.messages << msg }

          # Determine the tool result: execute it or inject a denial string.
          tool_result =
            if approved
              tool_instance = chat.tools[checkpoint.pending_tool_name.to_sym]
              tool_instance ? tool_instance.call(checkpoint.pending_tool_args) : "Tool not found."
            else
              "Tool execution denied."
            end

          # Inject the tool result so the LLM can continue.
          chat.add_message(
            role: :tool,
            content: tool_result.to_s,
            tool_call_id: checkpoint.pending_tool_call_id
          )

          # Continue the React loop.
          response = chat.complete

          output = response.content
          usage = Phronomy::TokenUsage.from_tokens(response.tokens)

          run_output_guardrails!(output)

          {output: output, suspended: false, messages: chat.messages, usage: usage}
        end

        private

        # Registers an on_tool_call hook on the chat object that raises SuspendSignal
        # when an approval-required tool is about to be executed and no synchronous
        # on_approval_required handler has been registered.
        #
        # Does nothing when:
        #   - a synchronous handler is already registered (@approval_handler is set), or
        #   - none of the agent's tools have requires_approval set.
        #
        # @param chat [RubyLLM::Chat]
        def _register_suspension_hook!(chat)
          return if @approval_handler
          return if self.class.tools.none? { |tc| tc.requires_approval }

          chat.on_tool_call do |tool_call|
            tool_instance = chat.tools[tool_call.name.to_sym]
            if tool_instance&.requires_approval
              raise SuspendSignal.new(
                tool_name: tool_call.name,
                args: tool_call.arguments,
                tool_call_id: tool_call.id
              )
            end
          end
        end
      end
    end
  end
end
