# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    module Concerns
      # Adds suspend/resume and tool-approval support to an agent.
      #
      # Included in {Phronomy::Agent::Base}. When a tool decorated with
      # +requires_approval true+ is called and no synchronous approval handler
      # has been registered, the invocation is suspended and a
      # @api private
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
        # @api private
        def on_approval_required(&block)
          @approval_handler = block
          self
        end

        # Registers a scope policy callable for this agent instance.
        #
        # The callable receives +(tool_class, scope, agent)+ and must return
        # +:allow+, +:reject+, or +:approve+.
        #
        # @example Reject all write-scoped tools
        #   agent.scope_policy = ->(_tc, scope, _agent) { scope == :write ? :reject : :allow }
        #
        # @param policy [#call]
        # @return [void]
        # @api public
        def scope_policy=(policy)
          @scope_policy = policy
        end

        # Sets the idempotency store used to guard against duplicate resumes.
        #
        # The store must respond to:
        # - +consumed?(checkpoint_id)+ ⇒ Boolean
        # - +consume!(checkpoint_id)+  ⇒ void; raises {Phronomy::CheckpointAlreadyResumedError} on duplicate
        #
        # Defaults to a per-instance {Phronomy::Agent::CheckpointStore} (in-memory, not thread-safe).
        # Assign a shared persistent store when resuming across processes (e.g. Redis-backed).
        # Custom stores are responsible for ensuring thread-safety if shared across threads.
        #
        # @param store [#consumed?, #consume!]
        # @return [void]
        # @api public
        def checkpoint_store=(store)
          @checkpoint_store = store
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
        #   or +{ output: nil, suspended: true, checkpoint: Phronomy::Agent::Checkpoint, messages: Array }+
        #   when a second approval-required tool is encountered during continuation
        # @raise [Phronomy::FilterBlockError] when an output filter rejects the value
        # @raise [Phronomy::CheckpointAlreadyResumedError] when the checkpoint has already been consumed
        # @api private
        def resume(checkpoint, approved:, config: {})
          # Guard against duplicate resumes using the idempotency store.
          _checkpoint_store.consume!(checkpoint.checkpoint_id)
          # Build a fresh chat with all tools registered.
          chat = build_chat

          # Re-apply system instructions and register tools so the LLM has the
          # same persona/context as the original invocation. build_context
          # includes all tool classes (static + handoff) via add_capability.
          context = build_context(checkpoint.original_input, messages: [])
          apply_instructions(chat, context[:system]) if context[:system]
          (context[:tool_classes] || []).each { |tc| chat.with_tool(prepare_tool_class(tc)) }

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

          # Re-register the suspension hook so that any further requires_approval
          # tools encountered during continuation are intercepted rather than
          # executed without approval (cascading / chained approval scenario).
          _register_suspension_hook!(chat)

          # Continue the LLM loop. Rescue SuspendSignal so that a second
          # approval-required tool produces a new checkpoint instead of running
          # without consent.
          begin
            response = chat.complete
          rescue SuspendSignal => signal
            new_checkpoint = Checkpoint.new(
              checkpoint_id: SecureRandom.uuid,
              agent_class: self.class.name,
              requested_at: Time.now.utc,
              thread_id: checkpoint.thread_id,
              original_input: checkpoint.original_input,
              messages: chat.messages.dup,
              pending_tool_name: signal.tool_name,
              pending_tool_args: signal.args,
              pending_tool_call_id: signal.tool_call_id
            )
            return {output: nil, suspended: true, checkpoint: new_checkpoint, messages: chat.messages}
          end

          output = response.content
          usage = Phronomy::TokenUsage.from_tokens(response.tokens)

          output = run_output_filters!(output)

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
        # @api private
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

        # Returns the checkpoint idempotency store for this instance, lazily
        # initialising a default in-memory {Phronomy::Agent::CheckpointStore}.
        #
        # @return [#consumed?, #consume!]
        # @api private
        def _checkpoint_store
          @checkpoint_store ||= CheckpointStore.new
        end
      end
    end
  end
end
