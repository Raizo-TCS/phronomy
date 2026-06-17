# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # Factory that builds a Phronomy::FSMSession configured for a single
    # Agent#invoke execution.
    #
    # This is the Agent counterpart to WorkflowRunner — it assembles the
    # FSMSession with the correct phase machine class, entry actions, and
    # context, then hands it to EventLoop for execution.
    #
    # == Usage (Phase 2 — not wired to invoke_once yet)
    #
    #   session = Agent::InvocationSession.build(
    #     agent:    my_agent,
    #     input:    "What is Ruby?",
    #     messages: [],
    #     config:   { thread_id: "t-1" }
    #   )
    #   # session is a Phronomy::FSMSession ready to be registered with EventLoop
    #
    # == Streaming mode
    #
    # Pass +mode: :stream+ and an +on_event:+ block to receive token/tool events.
    # The state graph is identical; only the +:calling_llm+ entry action differs.
    #
    # @api private
    class InvocationSession
      # States that have an automatic transition after their action completes.
      AUTO_STATE_SET = {
        idle: true,
        filtering_input: true,
        building_context: true,
        calling_llm: true,
        executing_tool: true,
        output_filtering: true
      }.freeze

      # All declared action states (terminals excluded).
      DECLARED_STATES = %i[
        idle filtering_input building_context calling_llm
        executing_tool awaiting_approval output_filtering
        completed blocked
      ].freeze

      # Builds a Phronomy::FSMSession for the given agent invocation.
      #
      # @param agent    [Phronomy::Agent::Base]
      # @param input    [String, Hash]
      # @param messages [Array]
      # @param config   [Hash]
      # @param mode     [:invoke, :stream]
      # @param on_event [Proc, nil] stream event callback (stream mode only)
      # @return [Phronomy::FSMSession]
      # @api private
      def self.build(agent:, input:, messages:, config:, mode: :invoke, on_event: nil)
        ctx = Agent::InvocationContext.new(
          agent: agent,
          input: input,
          messages: messages,
          config: config
        )

        actions = (mode == :stream && on_event) ?
          build_stream_entry_actions(agent, on_event) :
          build_entry_actions(agent)

        Phronomy::FSMSession.new(
          id: config[:thread_id] || SecureRandom.uuid,
          context: ctx,
          entry_point: :idle,
          phase_machine_class: Agent::PhaseMachineBuilder.new.build,
          entry_actions: actions,
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: %i[awaiting_approval],
          external_events: {
            approve: [{from: :awaiting_approval, to: :executing_tool, guard: nil}],
            reject: [{from: :awaiting_approval, to: :blocked, guard: nil}]
          },
          recursion_limit: agent.class.max_iterations
        )
      end

      # ---------------------------------------------------------------------------
      # Entry action builders
      # Each lambda receives the InvocationContext and may return a Task (async)
      # or update the context and return the context (sync).
      # ---------------------------------------------------------------------------

      # @api private
      def self.build_entry_actions(agent)
        {
          # :idle has no action — FSMSession auto-transitions to :filtering_input
          filtering_input: [method(:filtering_input_action).curry.call(agent)],
          building_context: [method(:building_context_action).curry.call(agent)],
          calling_llm: [method(:calling_llm_action).curry.call(agent)],
          executing_tool: [method(:executing_tool_action).curry.call(agent)],
          output_filtering: [method(:output_filtering_action).curry.call(agent)]
        }
      end
      private_class_method :build_entry_actions

      # @api private
      def self.build_stream_entry_actions(agent, on_event)
        build_entry_actions(agent).merge(
          calling_llm: [method(:calling_llm_stream_action).curry.call(agent, on_event)]
        )
      end
      private_class_method :build_stream_entry_actions

      # ----------------------------------------------------------------
      # Individual entry action implementations
      # ----------------------------------------------------------------

      def self.filtering_input_action(agent, ctx)
        begin
          ctx.input = agent.send(:run_input_filters!, ctx.input)
        rescue Phronomy::FilterBlockError => e
          ctx.input_blocked = true
          ctx.block_error = e
        end
        ctx
      end
      private_class_method :filtering_input_action

      def self.building_context_action(agent, ctx)
        ctx.chat = agent.send(:build_chat)
        context = agent.send(
          :build_context,
          ctx.input,
          messages: ctx.messages,
          thread_id: ctx.thread_id,
          config: ctx.config,
          budget: agent.send(:build_token_budget),
          instruction: agent.send(:build_instructions, ctx.input),
          tools: agent.class.tools + agent.send(:_handoff_tools)
        )
        agent.send(:_apply_context_to_chat, ctx.chat, context)
        ctx
      end
      private_class_method :building_context_action

      def self.calling_llm_action(agent, ctx)
        # Returns a Task — FSMSession will await it asynchronously.
        user_message = agent.send(:extract_message, ctx.input)
        Phronomy::Runtime.instance.spawn(name: "agent-llm:#{ctx.thread_id}") do
          adapter = Phronomy.configuration.llm_adapter
          response = adapter.complete_async(ctx.chat, user_message, config: ctx.config).await
          ctx.output = response.content
          ctx.usage = Phronomy::TokenUsage.from_tokens(response.tokens)
          ctx.messages = ctx.chat.messages
          ctx.tool_call_pending = response.tool_call?
          ctx
        end
      end
      private_class_method :calling_llm_action

      def self.calling_llm_stream_action(agent, on_event, ctx)
        user_message = agent.send(:extract_message, ctx.input)
        Phronomy::Runtime.instance.spawn(name: "agent-llm-stream:#{ctx.thread_id}") do
          adapter = Phronomy.configuration.llm_adapter
          chunk_queue = Phronomy::Concurrency::AsyncQueue.new(
            max_size: Phronomy.configuration.stream_queue_max_size
          )
          pending = adapter.stream_async(
            ctx.chat, user_message,
            config: ctx.config,
            enqueue_to: chunk_queue
          )
          loop do
            chunk = chunk_queue.pop
            break if chunk.nil?
            on_event.call(Phronomy::Agent::StreamEvent.new(
              type: :token, payload: {content: chunk.content}
            ))
          end
          response = pending.await
          ctx.output = response.content
          ctx.usage = Phronomy::TokenUsage.from_tokens(response.tokens)
          ctx.messages = ctx.chat.messages
          ctx.tool_call_pending = response.tool_call?
          ctx
        end
      end
      private_class_method :calling_llm_stream_action

      def self.executing_tool_action(agent, ctx)
        # Tool execution is handled inside RubyLLM's chat loop.
        # After calling_llm returns tool_call_pending? == true, we continue
        # the LLM call cycle (chat.complete) to let RubyLLM execute the tool.
        # The result is written back via on_tool_result callbacks.
        # approval_required is set if the tool's requires_approval flag is active.
        #
        # NOTE: Full tool execution wiring is completed in Phase 2 when
        # invoke_once is replaced. This placeholder sets tool_call_pending
        # to false and returns so the FSM can transition out of :executing_tool.
        ctx.tool_call_pending = false
        ctx.approval_required = false
        ctx
      end
      private_class_method :executing_tool_action

      def self.output_filtering_action(agent, ctx)
        begin
          ctx.output = agent.send(:run_output_filters!, ctx.output)
        rescue Phronomy::FilterBlockError => e
          ctx.output_blocked = true
          ctx.block_error = e
        end
        ctx
      end
      private_class_method :output_filtering_action
    end
  end
end
