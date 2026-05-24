# frozen_string_literal: true

require "securerandom"

module Phronomy
  module Agent
    # EventLoop-registered execution unit for a single agent invocation.
    #
    # +AgentFSM+ implements the minimal interface expected by {Phronomy::EventLoop}
    # (+#id+, +#start+, +#handle+) so it can be managed alongside
    # {Phronomy::FSMSession} instances.  It is *not* a traditional finite-state
    # machine; the name reflects its role in the EventLoop rather than internal
    # state transitions.
    #
    # == Execution model
    #
    # {#start} is called by the EventLoop on the +:start+ event.  It immediately
    # returns after spawning a {Phronomy::Task} that runs the agent's full
    # invocation pipeline (via +_invoke_impl+).  The EventLoop thread is never
    # blocked by agent execution.
    #
    # Inside the task, {Agent::Base#build_chat} returns a
    # {ParallelToolChat} instance when EventLoop mode is enabled, allowing
    # concurrent tool dispatch when the LLM returns multiple tool calls in one
    # response.
    #
    # == Completion events
    #
    # On *success*:
    #   - Posts +:finished+ to this FSM's own +#id+ so the EventLoop cleans up
    #     its registry entry and unblocks any +completion_queue.pop+ caller.
    #   - When +parent_id+ is set (child-FSM pattern), additionally posts
    #     +:child_completed+ to +parent_id+, carrying the result hash as the
    #     event payload.  The parent {FSMSession} must declare an +on:+ transition
    #     for +:child_completed+ to advance correctly.
    #
    # On *error*:
    #   - Posts +:error+ to this FSM's own +#id+.  The EventLoop propagates the
    #     exception through the +completion_queue+ so that the original caller of
    #     +Agent::Base#invoke+ (in EventLoop mode) receives and re-raises it.
    #
    # == Standalone usage (blocking caller)
    #
    #   Phronomy.configure { |c| c.event_loop = true }
    #   result = MyAgent.new.invoke("Hello!")   # => { output:, messages:, usage: }
    #
    # {Agent::Base#invoke} detects EventLoop mode, creates an +AgentFSM+, registers
    # it via {EventLoop#register}, and blocks the *calling* thread on the returned
    # +completion_queue+ until the agent finishes.
    #
    # == Child-FSM usage (non-blocking, inside a Workflow)
    #
    #   state :run_agent
    #   entry :run_agent, ->(ctx) { MyAgent.new.run_as_child(ctx.query, ctx: ctx) }
    #   transition from: :run_agent, on: :child_completed, to: :process_result
    #
    # {Agent::Base#run_as_child} creates an +AgentFSM+ with +parent_id+ set to
    # +ctx.thread_id+, registers it with the EventLoop, and returns immediately.
    # The parent {FSMSession} waits for the +:child_completed+ event.
    # @api private
    class FSM
      # @return [String] unique identifier used as the EventLoop target_id
      attr_reader :id

      # @return [Symbol] current internal phase (:idle, :running)
      attr_reader :current_phase

      # @param agent     [Phronomy::Agent::Base]  agent instance to run
      # @param input     [String, Hash]           user input passed to +invoke_once+
      # @param messages  [Array]                  prior conversation history
      # @param thread_id [String, nil]            conversation thread id;
      #                                           auto-generated when nil
      # @param config    [Hash]                   invocation config forwarded to
      #                                           +_invoke_impl+
      # @param parent_id [String, nil]  EventLoop id of the parent FSMSession;
      #                                  when set, a +:child_completed+ event
      #                                  is posted on completion.  The result
      #                                  is delivered exclusively as the event
      #                                  payload — no cross-thread writes to the
      #                                  parent WorkflowContext are performed.
      #
      # @api private
      def initialize(agent:, input:, messages: [], thread_id: nil, config: {}, parent_id: nil)
        @agent = agent
        @input = input
        @messages = Array(messages).dup
        @thread_id = thread_id || SecureRandom.uuid
        @config = config
        @parent_id = parent_id
        @id = @thread_id
        @current_phase = :idle
      end

      # Called by {EventLoop} on the +:start+ event.
      # Transitions to +:running+ and spawns the agent task.
      def start
        @current_phase = :running
        spawn_agent_task
      end

      # Called by {EventLoop} for external events dispatched to this id.
      # +AgentFSM+ is fully driven by its own IO thread and does not respond
      # to external events after {#start}.
      def handle(_event)
        # No-op: AgentFSM is driven entirely by its IO thread.
      end

      private

      # Spawns a {Phronomy::Task} that runs the agent invocation pipeline.
      # Captures all instance variables by value so the task closure is
      # safe even if the FSM object is modified (though it is not in practice).
      def spawn_agent_task
        agent = @agent
        input = @input
        messages = @messages
        thread_id = @thread_id
        config = @config
        fsm_id = @id
        parent_id = @parent_id

        # Agent IO work (LLM / tool calls) must run in a real background thread.
        # Using Runtime.instance.spawn with a cooperative (FakeScheduler) backend
        # would execute the block synchronously, blocking the calling thread and
        # preventing the EventLoop from dispatching other events.
        Phronomy::Task.spawn(
          name: "agent-fsm:#{fsm_id}",
          backend_class: Phronomy::Task::ThreadBackend
        ) do
          result = agent.send(:_invoke_impl,
            input,
            messages: messages,
            thread_id: thread_id,
            config: config)

          if parent_id
            # Result is delivered exclusively as the :child_completed payload.
            # The parent Workflow task is the sole owner of WorkflowContext
            # and applies the result after receiving the event.
            Phronomy::EventLoop.instance.post(
              Phronomy::Event.new(type: :child_completed, target_id: parent_id, payload: result)
            )
          end

          Phronomy::EventLoop.instance.post(
            Phronomy::Event.new(type: :finished, target_id: fsm_id, payload: result)
          )
        rescue => e
          if parent_id
            Phronomy::EventLoop.instance.post(
              Phronomy::Event.new(type: :child_failed, target_id: parent_id, payload: e)
            )
          end

          Phronomy::EventLoop.instance.post(
            Phronomy::Event.new(type: :error, target_id: fsm_id, payload: e)
          )

          # Context caches are instance variables; no thread-local cleanup needed.
        end
      end
    end
  end
end
