# frozen_string_literal: true

require "state_machines"

module Phronomy
  module Agent
    module Lifecycle
      # Builds the anonymous state-machine Class used by {WorkflowRunner} to track
      # workflow phase transitions.
      #
      # Extracted from {WorkflowRunner#build_phase_machine_class} to reduce the
      # span of WorkflowRunner's initializer and to give the FSM construction
      # logic an explicit, testable home.
      #
      # Call {#build} to obtain the generated +Class+. The returned class responds
      # to +#context+ / +#context=+ and +#async_pending+ / +#async_pending=+, and
      # has a +state_machine :phase+ definition with all registered transitions and
      # callbacks.
      #
      # @api private
      class PhaseMachineBuilder
        # @param entry_point      [Symbol]  initial state for the phase machine
        # @param declared_states  [Array<Symbol>]  all states declared in the workflow
        # @param wait_state_names [Array<Symbol>]  states that wait for external events
        # @param external_events  [Hash{Symbol => Array<Hash>}]
        #   +{ event_name => [{from:, to:, guard:}, ...] }+
        # @param entry_actions    [Hash{Symbol => Array<#call>}]
        #   +{ state_name => [callable, ...] }+
        # @param action_timeouts  [Hash{Symbol => Numeric}]
        #   +{ state_name => seconds }+
        # @param auto_transitions [Array<Hash>]
        #   +[{ from:, to:, guard: }, ...]+ — all auto-fire transitions
        # @param exit_actions     [Hash{Symbol => Array<#call>}]
        #   +{ state_name => [callable, ...] }+
        def initialize(
          entry_point:,
          declared_states:,
          wait_state_names:,
          external_events:,
          entry_actions:,
          action_timeouts:,
          auto_transitions:,
          exit_actions:
        )
          @entry_point = entry_point
          @declared_states = declared_states
          @wait_state_names = wait_state_names
          @external_events = external_events
          @entry_actions = entry_actions
          @action_timeouts = action_timeouts
          @auto_transitions = auto_transitions
          @exit_actions = exit_actions
        end

        # Constructs and returns the anonymous phase-machine Class.
        #
        # @return [Class] an anonymous class with a +state_machine :phase+ definition
        # @raise [ArgumentError] if state_machines raises during class construction
        def build
          entry = @entry_point
          all_states = (@declared_states + @wait_state_names + [:__end__]).uniq
          auto_trans = @auto_transitions
          ext_events = @external_events
          entry_acts = @entry_actions
          exit_acts = @exit_actions
          act_timeouts = @action_timeouts

          Class.new do
            # Holds the current WorkflowContext so guards and callbacks can read it.
            attr_accessor :context

            # Set to true by an entry action that returned an awaitable Task.
            # When true, FSMSession skips the automatic advance_or_halt step and
            # waits for the async worker thread to post a state_completed event back.
            attr_accessor :async_pending

            state_machine :phase, initial: entry do
              all_states.each { |s| state s }

              # Auto-fire transitions: all auto transitions unified under :state_completed.
              # Includes unguarded (unconditional) and guarded (conditional) transitions.
              # Declaration order is preserved; guards are evaluated before unguarded fallbacks.
              event :state_completed do
                auto_trans.each do |t|
                  if t[:guard]
                    guard_proc = t[:guard]
                    transition t[:from] => t[:to], :if => ->(m) { guard_proc.call(m.context) }
                  else
                    transition t[:from] => t[:to]
                  end
                end
              end

              # External events: human-in-the-loop triggers from wait states.
              ext_events.each do |ev_name, transitions|
                event ev_name do
                  transitions.each do |t|
                    if t[:guard]
                      guard_proc = t[:guard]
                      transition t[:from] => t[:to], :if => ->(m) { guard_proc.call(m.context) }
                    else
                      transition t[:from] => t[:to]
                    end
                  end
                end
              end

              # Entry callbacks: fire after_transition into each state.
              #    Each callable is registered as a separate callback; state_machines
              #    accumulates them and fires in declaration order.
              #    If the callable returns a WorkflowContext (e.g. via s.merge(...)),
              #    the returned context replaces the current one on the tracker.
              entry_acts.each do |state_name, callables|
                callables.each do |callable|
                  timeout_secs = act_timeouts[state_name]
                  after_transition to: state_name do |machine|
                    result = callable.call(machine.context)
                    if result.is_a?(Phronomy::Task)
                      if Phronomy.configuration.event_loop
                        # EventLoop mode: await in a background task so the EventLoop
                        # thread is not blocked. Signal async_pending so FSMSession
                        # skips the automatic advance_or_halt step.
                        machine.async_pending = true
                        ctx_ref = machine.context
                        thread_id = ctx_ref.thread_id
                        Phronomy::Runtime.instance.spawn(name: "wf-await-#{thread_id}") do
                          if timeout_secs
                            if result.join(timeout_secs).nil?
                              result.cancel!
                              raise Phronomy::ActionTimeoutError,
                                "Action in state #{state_name.inspect} timed out after #{timeout_secs}s"
                            end
                          end
                          task_result = result.await
                          if task_result.is_a?(Phronomy::WorkflowContext)
                            Phronomy::EventLoop.instance.post(
                              Phronomy::Event.new(
                                type: :action_completed,
                                target_id: thread_id,
                                payload: task_result
                              )
                            )
                          else
                            Phronomy::EventLoop.instance.post(
                              Phronomy::Event.new(type: :state_completed, target_id: thread_id, payload: nil)
                            )
                          end
                        rescue => e
                          Phronomy::EventLoop.instance.post(
                            Phronomy::Event.new(type: :error, target_id: thread_id, payload: e)
                          )
                        end
                      else
                        # Non-EventLoop mode: block synchronously on the task result.
                        if timeout_secs
                          if result.join(timeout_secs).nil?
                            result.cancel!
                            raise Phronomy::ActionTimeoutError,
                              "Action in state #{state_name.inspect} timed out after #{timeout_secs}s"
                          end
                        end
                        task_result = result.await
                        machine.context = task_result if task_result.is_a?(Phronomy::WorkflowContext)
                      end
                    elsif result.is_a?(Phronomy::WorkflowContext)
                      machine.context = result
                    end
                  end
                end
              end

              # Exit callbacks: fire before_transition out of each state.
              #    Each callable is registered as a separate callback; state_machines
              #    accumulates them and fires in declaration order.
              exit_acts.each do |state_name, callables|
                callables.each do |callable|
                  before_transition from: state_name do |machine|
                    callable.call(machine.context)
                  end
                end
              end
            end
          end
        rescue => e
          raise ArgumentError, "Failed to build phase machine: #{e.message}"
        end
      end
    end
  end
end
