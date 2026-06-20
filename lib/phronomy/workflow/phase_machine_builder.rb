# frozen_string_literal: true

require "state_machines"

module Phronomy
  class Workflow
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
      # @api private
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
      # @api private
      def build
        entry = @entry_point
        all_states = (@declared_states + @wait_state_names + [:__end__]).uniq
        auto_trans = @auto_transitions
        ext_events = @external_events
        entry_acts = @entry_actions
        exit_acts = @exit_actions
        act_timeouts = @action_timeouts
        build_cb = method(:build_entry_callback)

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
                cb = build_cb.call(callable, state_name, act_timeouts[state_name])
                after_transition to: state_name, &cb
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

      private

      # Returns a proc suitable for use as an +after_transition+ callback.
      #
      # The returned proc accepts a single argument (the phase machine instance),
      # invokes the entry action callable with the current context, then delegates
      # the result to {#handle_entry_action_result}.  Capturing this in the
      # builder's scope lets the anonymous +Class.new+ block stay slim.
      #
      # @param callable     [#call]  the entry action
      # @param state_name   [Symbol] name of the target state (for error messages)
      # @param timeout_secs [Numeric, nil] seconds before ActionTimeoutError
      # @return [Proc]
      # @api private
      def build_entry_callback(callable, state_name, timeout_secs)
        handle = method(:handle_entry_action_result)
        ->(machine) {
          result = callable.call(machine.context)
          handle.call(machine, result, state_name, timeout_secs)
        }
      end

      # Dispatches the return value of an entry action callable.
      #
      # - +Phronomy::Task+            → async or blocking task handling
      # - +Phronomy::WorkflowContext+ → replaces the machine's context directly
      # - anything else               → ignored
      #
      # @param machine       [Object]           phase machine instance
      # @param result        [Object]           return value of the entry callable
      # @param state_name    [Symbol]           name of the entered state
      # @param timeout_secs  [Numeric, nil]     optional timeout in seconds
      # @api private
      def handle_entry_action_result(machine, result, state_name, timeout_secs)
        if result.is_a?(Phronomy::Task)
          dispatch_task_in_event_loop(machine, result, state_name, timeout_secs)
        elsif result.is_a?(Phronomy::WorkflowContext)
          machine.context = result
        end
      end

      # Handles a +Phronomy::Task+ return value in EventLoop mode.
      #
      # Marks the machine as async-pending and spawns a cooperative background
      # task that awaits the result, then posts the appropriate event back to
      # the EventLoop.  +FSMSession+ will skip the automatic +advance_or_halt+
      # step while +async_pending+ is true.
      #
      # @param machine       [Object]       phase machine instance
      # @param result        [Phronomy::Task]
      # @param state_name    [Symbol]
      # @param timeout_secs  [Numeric, nil]
      # @api private
      def dispatch_task_in_event_loop(machine, result, state_name, timeout_secs)
        machine.async_pending = true
        thread_id = machine.context.thread_id
        if timeout_secs
          Phronomy::Runtime.instance.timer_queue.schedule(seconds: timeout_secs) do
            next if result.done?

            Phronomy::EventLoop.instance.post(
              Phronomy::Event.new(
                type: :error,
                target_id: thread_id,
                payload: Phronomy::ActionTimeoutError.new(
                  "Action in state #{state_name.inspect} timed out after #{timeout_secs}s"
                )
              )
            )
          end
        end
        result.on_complete do |task_result, error|
          if error
            Phronomy::EventLoop.instance.post(
              Phronomy::Event.new(type: :error, target_id: thread_id, payload: error)
            )
            next
          end
          ev = if task_result.is_a?(Phronomy::WorkflowContext)
            Phronomy::Event.new(type: :action_completed, target_id: thread_id, payload: task_result)
          else
            Phronomy::Event.new(type: :state_completed, target_id: thread_id, payload: nil)
          end
          Phronomy::EventLoop.instance.post(ev)
        end
      end

      # Handles a +Phronomy::Task+ return value in non-EventLoop mode.
      #
      # Blocks the current execution context until the task completes or the
      # optional timeout elapses.
      #
      # @param machine       [Object]       phase machine instance
      # @param result        [Phronomy::Task]
      # @param state_name    [Symbol]
      # @param timeout_secs  [Numeric, nil]
      # @api private
      def await_task_blocking(machine, result, state_name, timeout_secs)
        enforce_timeout!(result, state_name, timeout_secs)
        task_result = result.wait_result
        machine.context = task_result if task_result.is_a?(Phronomy::WorkflowContext)
      end

      # Raises +ActionTimeoutError+ if the task does not complete within
      # +timeout_secs+.  No-op when +timeout_secs+ is +nil+.
      #
      # @param result       [Phronomy::Task]
      # @param state_name   [Symbol]
      # @param timeout_secs [Numeric, nil]
      # @api private
      def enforce_timeout!(result, state_name, timeout_secs)
        return unless timeout_secs
        return unless result.join(timeout_secs).nil?

        result.cancel!
        raise Phronomy::ActionTimeoutError,
          "Action in state #{state_name.inspect} timed out after #{timeout_secs}s"
      end
    end
  end
end
