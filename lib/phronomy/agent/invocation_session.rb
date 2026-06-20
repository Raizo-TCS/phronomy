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
    # == Usage
    #
    #   session = Agent::InvocationSession.build(
    #     agent:    my_agent,
    #     input:    "What is Ruby?",
    #     messages: [],
    #     config:   { thread_id: "t-1" }
    #   )
    #   completion_queue = Phronomy::EventLoop.instance.register(session)
    #   ctx = completion_queue.pop
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

        # Calculate recursion_limit for the FSM:
        # Base states: idle→filtering_input→building_context→calling_llm→
        #              output_filtering→completed = 6 transitions
        # Each tool call loop: calling_llm→executing_tool→calling_llm = 2 transitions
        # Safety margin: +4
        iterations = agent.class.max_iterations || 10
        fsm_recursion_limit = 6 + (iterations * 2) + 4

        # Entry actions are registered as after_transition callbacks in the
        # phase machine class. Pass empty hash to FSMSession (it uses @entry_actions
        # only for the entry_point state, which has no action for :idle).
        phase_machine = Agent::PhaseMachineBuilder.new(entry_actions: actions).build
        session_id = config[:thread_id] || SecureRandom.uuid

        Phronomy::FSMSession.new(
          id: session_id,
          context: ctx,
          entry_point: :idle,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: %i[awaiting_approval],
          external_events: {
            approve: [{from: :awaiting_approval, to: :executing_tool, guard: nil}],
            reject: [{from: :awaiting_approval, to: :blocked, guard: nil}]
          },
          recursion_limit: fsm_recursion_limit
        )
      end

      # Builds a FSMSession that resumes an existing InvocationContext
      # from a wait state (e.g. :awaiting_approval) using an external event.
      #
      # @param agent        [Phronomy::Agent::Base]
      # @param context      [Phronomy::Agent::InvocationContext] suspended context
      # @param resume_event [Symbol] e.g. :approve or :reject
      # @param resume_phase [Symbol] the wait state to resume from
      # @return [Phronomy::FSMSession]
      # @api private
      def self.build_for_resume(agent:, context:, resume_event:, resume_phase:)
        actions = build_entry_actions(agent)
        phase_machine = Agent::PhaseMachineBuilder.new(entry_actions: actions).build

        iterations = agent.class.max_iterations || 10
        fsm_recursion_limit = 6 + (iterations * 2) + 4

        Phronomy::FSMSession.new(
          id: context.session_id || SecureRandom.uuid,
          context: context,
          entry_point: :idle,
          phase_machine_class: phase_machine,
          entry_actions: {},
          auto_state_set: AUTO_STATE_SET,
          declared_states: DECLARED_STATES,
          wait_state_names: %i[awaiting_approval],
          external_events: {
            approve: [{from: :awaiting_approval, to: :executing_tool, guard: nil}],
            reject: [{from: :awaiting_approval, to: :blocked, guard: nil}]
          },
          recursion_limit: fsm_recursion_limit,
          resume_event: resume_event,
          resume_phase: resume_phase
        )
      end

      # ---------------------------------------------------------------------------
      # Entry action builders
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
        # Run before-completion hooks (e.g. memory injection) once per invocation.
        agent.send(:run_before_completion_hooks!, ctx.chat, ctx.config)
        # Register the tool-call interceptor so every tool call routes through
        # :executing_tool in the FSM instead of executing inside RubyLLM's loop.
        ctx.chat.on_tool_call do |tool_call|
          raise Phronomy::Agent::ToolCallIntercepted.new(tool_call)
        end
        ctx
      end
      private_class_method :building_context_action

      def self.calling_llm_action(agent, ctx)
        # Returns a Task — FSMSession will await it asynchronously.
        # First call: send user message. Subsequent calls (after tool execution):
        # pass nil so the adapter calls chat.complete (continue after tool result).
        user_message = ctx.user_message_sent ? nil : agent.send(:extract_message, ctx.input)
        Phronomy::Runtime.instance.spawn(name: "agent-llm:#{ctx.thread_id}") do
          agent.send(:check_cancellation!, ctx.config, "invocation cancelled before LLM call")
          adapter = Phronomy.configuration.llm_adapter
          begin
            response = adapter.complete_async(ctx.chat, user_message, config: ctx.config).blocking_wait
            ctx.user_message_sent = true
            ctx.output = response.content
            ctx.usage = Phronomy::TokenUsage.from_tokens(response.tokens)
            ctx.messages = ctx.chat.messages
            ctx.tool_call_pending = false
          rescue Phronomy::Agent::ToolCallIntercepted => e
            ctx.user_message_sent = true
            ctx.pending_tool_call = e.tool_call
            ctx.tool_call_pending = true
            ctx.messages = ctx.chat.messages
          end
          ctx
        end
      end
      private_class_method :calling_llm_action

      def self.calling_llm_stream_action(agent, on_event, ctx)
        user_message = ctx.user_message_sent ? nil : agent.send(:extract_message, ctx.input)
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
          response = pending.blocking_wait
          ctx.user_message_sent = true
          ctx.output = response.content
          ctx.usage = Phronomy::TokenUsage.from_tokens(response.tokens)
          ctx.messages = ctx.chat.messages
          ctx.tool_call_pending = false
          ctx
        end
      end
      private_class_method :calling_llm_stream_action

      def self.executing_tool_action(agent, ctx)
        tc = ctx.pending_tool_call
        tool_instance = ctx.chat.tools[tc.name.to_sym]

        unless tool_instance
          # Tool not found — inject an error result and continue the LLM loop.
          ctx.chat.add_message(
            role: :tool,
            content: "Tool not found.",
            tool_call_id: tc.id
          )
          ctx.pending_tool_call = nil
          ctx.tool_call_pending = false
          ctx.approval_required = false
          return ctx
        end

        if tool_instance.requires_approval && !ctx.sync_approval_handler
          if ctx.approved
            # Human approved via Agent.approve — execute the tool and continue.
            ctx.approved = false  # consume the approval flag
          else
            # No sync handler and not yet approved — suspend for HITL.
            ctx.approval_required = true
            return ctx
          end
        end

        # Execute the tool off the EventLoop thread via Runtime.instance.spawn.
        # Tool implementations (e.g. Orchestrator sub-agent dispatch) may call
        # agent.invoke_async().wait_result which would deadlock if run directly on the
        # EventLoop dispatch thread. Returning a Task causes
        # PhaseMachineBuilder#dispatch_task to await the result off the EventLoop
        # and post :action_completed back when done.
        tc_id = tc.id
        tc_args = tc.arguments
        tc_name = tc.name
        Phronomy::Runtime.instance.spawn(name: "tool-exec:#{tc_name}") do
          result = tool_instance.call(tc_args)
          ctx.chat.add_message(
            role: :tool,
            content: result.to_s,
            tool_call_id: tc_id
          )
          ctx.pending_tool_call = nil
          ctx.tool_call_pending = false
          ctx.approval_required = false
          ctx
        end
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
