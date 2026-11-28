# frozen_string_literal: true

require "time"

module Phronomy
  module MultiAgent
    # Durable turn coordination using Agent's public exact-execution operations.
    # @api public
    class HandoffRunner
      MAX_HANDOFFS = 20
      attr_reader :main_agent, :handoffs

      def initialize(main_agent:, persistence:, handoffs: [])
        @main_agent, @persistence, @handoffs = main_agent, persistence, Array(handoffs).freeze
        raise ArgumentError, "handoffs must contain MultiAgent::Handoff" unless @handoffs.all? { |edge| edge.is_a?(Handoff) }
        @agents = ([main_agent] + @handoffs.flat_map { |edge| [edge.source_agent, edge.target_agent] }).uniq.to_h { |agent| [agent.agent_id, agent] }.freeze
        unless @agents.values.all? { |agent| agent.persistence.equal?(@persistence.agent_store) }
          raise Phronomy::ConfigurationError, "Handoff graph and coordination store must share the same Agent store"
        end
        if @handoffs.group_by { |edge| [edge.source_agent.agent_id, edge.target_agent.agent_id] }.any? { |_, edges| edges.size > 1 }
          raise ArgumentError, "Duplicate Source/Target Handoff edges"
        end
        @bindings = @handoffs.group_by { |edge| edge.source_agent.agent_id }.transform_values { |edges| edges.map { |edge| HandoffCapabilityFactory.build(edge) }.freeze }.freeze
        @environment = ExecutionEnvironment.current
        @admissions = @environment.admissions
      end

      def invoke(input, config: {})
        assert_execution_thread!(:invoke)
        trace = Phronomy::Tracing::Automatic.start("multi_agent.turn", input: input, main_agent_id: main_agent.agent_id)
        error = result = nil
        config = config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new)
        @admissions.admit!(main_agent)
        admitted = true
        state = load_state
        chain_entry = state.pending_source_execution_id unless state.phase == "stable"
        count = 0
        loop do
          active = agent_for(state.active_agent_id)
          wiring = execution_config(active, state, config)
          result = if state.phase == "stable"
            unfinished = @persistence.agent_store.active_executions(agent_id: active.agent_id)
            if unfinished.empty?
              active.invoke(input, config: wiring)
            else
              exact = unfinished.fetch(0)
              unless unfinished.size == 1 && exact.reservation&.correlation == handoff_owner
                raise Phronomy::Persistence::StateConflictError, "Active execution belongs to another turn"
              end
              wiring[:cancellation_token].cancel! if Array(state.metadata["cancelled_execution_ids"]).include?(exact.execution_id)
              active.resume_async(exact.execution_id, config: wiring).wait_result
            end
          else
            start_target(active, state, wiring)
          end
          chain_entry ||= result.fetch(:execution_id)
          observed = @persistence.agent_store.observe_execution(agent_id: active.agent_id, execution_id: result.fetch(:execution_id))
          if observed.status == :handed_off
            count += 1
            raise Phronomy::HandoffError, "Exceeded maximum Handoffs in one turn" if count > MAX_HANDOFFS
            state = @persistence.handoff_states.load(main_agent.agent_id)
            next
          end
          raise Phronomy::ExecutionRehydrationRequiredError, "Handoff requires approval or recovery" if observed.active?
          finalize_terminal(observed, chain_entry)
          observed.value!
          return result.reject { |key, _| key.to_s.start_with?("_phronomy_") || key == :handoff_request }.merge(agent: active)
        end
      rescue Phronomy::CancellationError => caught
        error = caught
        cancel(state.pending_source_execution_id) if state && state.phase != "stable"
        raise
      rescue => caught
        error = caught
        raise
      ensure
        @admissions.release!(main_agent) if admitted
        Phronomy::Tracing::Automatic.finish(trace, output: result && result[:output], error: error) if trace
      end

      # Continues only the recorded chain rooted at this execution identity.
      # Terminal history is returned without invoking another turn. An exact
      # unsuccessful pending Target first finalizes its parent routing; a saved
      # failure remains a failure. result is the read-only observation API. A retained
      # dispatch save must be reconciled explicitly through its original Agent
      # before this method can continue; resume never chooses a retry policy.
      # The result contains durable execution fields plus the terminal Agent,
      # not transient fields from the original live invocation. Saved failures
      # keep the Runner's existing exception semantics. MAX_HANDOFFS limits the
      # newly driven segment; already recorded links are only read and checked.
      # @param execution_id [String] an execution belonging to this Handoff anchor
      # @return [Hash] the saved leaf result and its Agent
      # @raise [ExecutionRehydrationRequiredError] when explicit recovery is needed
      # @api public
      def resume(execution_id, config: {})
        assert_execution_thread!(:resume)
        unless execution_id.is_a?(String) && !execution_id.empty?
          raise ArgumentError, "execution_id must be a nonempty String"
        end
        trace = Phronomy::Tracing::Automatic.start("multi_agent.resume", execution_id: execution_id, main_agent_id: main_agent.agent_id)
        error = result = nil
        config = config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new)
        saved = @persistence.handoff_leaf(execution_id, main_agent_id: main_agent.agent_id)
        if saved.terminal?
          finalize_terminal(saved, execution_id)
          return result = saved.value!.merge(agent: agent_for(saved.agent_id))
        end
        @admissions.admit!(main_agent)
        admitted = true
        count = 0
        loop do
          state, leaf = resumable_turn(execution_id)
          active = agent_for(leaf.agent_id)
          if leaf.terminal?
            finalize_terminal(leaf, execution_id)
            return result = leaf.value!.merge(agent: active)
          end
          require_dispatch_recovery_resolved!(active, leaf.execution_id)
          wiring = execution_config(active, state, config)
          result = if leaf.absent?
            start_target(active, state, wiring)
          else
            active.resume_async(leaf.execution_id, config: wiring).wait_result
          end
          observed = @persistence.agent_store.observe_execution(agent_id: active.agent_id, execution_id: result.fetch(:execution_id))
          raise Phronomy::ExecutionRehydrationRequiredError, "Handoff requires approval or recovery" if observed.active?
          if observed.status == :handed_off
            count += 1
            raise Phronomy::HandoffError, "Exceeded maximum Handoffs in one continuation segment" if count > MAX_HANDOFFS
          end
        end
      rescue Phronomy::CancellationError => caught
        error = caught
        cancel(execution_id) if admitted && config[:cancellation_token].cancelled?
        raise
      rescue => caught
        error = caught
        raise
      ensure
        @admissions.release!(main_agent) if admitted
        Phronomy::Tracing::Automatic.finish(trace, output: result && result[:output], error: error) if trace
      end

      def cancel(execution_id)
        assert_execution_thread!(:cancel)
        leaf = intended = nil
        begin
          @persistence.transaction do |records, scope|
            routing = records.handoff_states.load_locked(main_agent.agent_id)
            # All leaf reads occur after the same guard used by target admission.
            leaf = @persistence.handoff_leaf(execution_id, main_agent_id: main_agent.agent_id, scope: scope)
            next if leaf.terminal?
            unless routing && (leaf.absent? ? routing.pending_target_execution_id == leaf.execution_id : routing.active_agent_id == leaf.agent_id)
              raise Phronomy::Persistence::StateConflictError, "Handoff no longer owns the requested turn"
            end
            @persistence.agent_store.guard_agents(scope, agent_ids: [main_agent.agent_id, leaf.agent_id])
            @persistence.agent_store.request_cancellation(agent_id: leaf.agent_id, execution_id: leaf.execution_id, scope: scope) unless leaf.absent?
            ids = (Array(routing.metadata["cancelled_execution_ids"]) + [leaf.execution_id]).uniq
            intended = routing.with(phase: leaf.absent? ? "stable" : routing.phase, metadata: routing.metadata.merge("cancelled_execution_ids" => ids))
            records.handoff_states.save(main_agent.agent_id, expected_revision: routing.handoff_revision, state: intended)
          end
        rescue => failure
          raise unless intended
          proof = Phronomy::Persistence::SaveOutcome.compare(before: nil, after: [intended.to_h, true], original_error: failure) do
            @persistence.transaction do |records, scope|
              current = records.handoff_states.load_locked(main_agent.agent_id)
              cancelled = leaf.absent? || @persistence.agent_store.cancellation_requested?(agent_id: leaf.agent_id, execution_id: leaf.execution_id, scope: scope)
              [current&.to_h, cancelled]
            end
          end
          raise failure unless proof.disposition == :committed
        end
        if leaf.terminal?
          finalize_terminal(leaf, execution_id)
          return leaf.to_result
        end
        @agents[leaf.agent_id]&.cancel_async(leaf.execution_id)&.wait_result if leaf.active?
        {execution_id: leaf.execution_id, cancellation_requested: true}.freeze
      end

      def result(execution_id)
        @persistence.handoff_result(execution_id, main_agent_id: main_agent.agent_id)
      end

      # Explicit history removal releases references before Agent purge is allowed.
      def forget_history!
        @persistence.forget_handoff(main_agent.agent_id)
      end

      private

      def assert_execution_thread!(operation)
        if Phronomy::WaitPolicy.blocking_forbidden?
          raise Phronomy::EventLoopReentrancyError, "HandoffRunner##{operation} cannot block EventLoop"
        end
        raise Phronomy::RuntimeShutdownError, "HandoffRunner belongs to a previous Runtime" unless @environment.current?
      end

      def agent_for(agent_id)
        @agents.fetch(agent_id) { raise Phronomy::ExecutionRehydrationRequiredError, "Handoff graph lacks Agent #{agent_id}" }
      end

      # Cancellation and terminal-history progress may run beside an admitted
      # invocation. The routing transaction serializes this idempotent effect.
      def finalize_terminal(target, execution_id)
        HandoffTerminalFinalization.new(persistence: @persistence,
          main_agent_id: main_agent.agent_id, agents: @agents).call(execution_id: execution_id, target: target)
      end

      def handoff_owner
        {"kind" => "handoff", "main_agent_id" => main_agent.agent_id}.freeze
      end

      def execution_config(active, state, config)
        context = state.active_handoff_context_ref && Phronomy::Agent::TransferContext.from_h(@persistence.contents.fetch_json(state.active_handoff_context_ref))
        config.merge(phronomy_control_bindings: @bindings.fetch(active.agent_id, []), phronomy_transfer_context: context,
          phronomy_execution_participant: HandoffParticipant.new(persistence: @persistence, main_agent_id: main_agent.agent_id, expected_revision: state.handoff_revision),
          phronomy_reservation: handoff_owner, phronomy_admission: ReservedChildAdmission.new(persistence: @persistence, owner: handoff_owner))
      end

      def start_target(active, state, wiring)
        saved = @persistence.agent_store.observe_execution(agent_id: active.agent_id,
          execution_id: state.pending_target_execution_id)
        # A saved failure needs parent cleanup, not current business wiring.
        return saved.to_result if %i[failed cancelled blocked].include?(saved.status)

        source = @persistence.agent_store.execution_identity(state.pending_source_execution_id)
        require_target_definition!(active, source.agent_id, state)
        wiring[:cancellation_token].cancel! if Array(state.metadata["cancelled_execution_ids"]).include?(state.pending_target_execution_id)
        reservation = Phronomy::Agent::ReservedExecution.new(agent_id: active.agent_id, execution_id: state.pending_target_execution_id, correlation: handoff_owner)
        active.start_reserved_async(reservation: reservation,
          input: wiring.fetch(:phronomy_transfer_context).responsibility, config: wiring).wait_result
      end

      def require_target_definition!(active, source_agent_id, state)
        unless @handoffs.any? { |edge| edge.source_agent.agent_id == source_agent_id && edge.target_agent.agent_id == active.agent_id }
          raise Phronomy::ExecutionRehydrationRequiredError, "Handoff graph lacks committed Source/Target edge"
        end
        unless active.class.agent_definition == state.metadata.fetch("target_definition").transform_keys(&:to_sym)
          raise Phronomy::ConfigurationError, "Handoff Target definition mismatch"
        end
      end

      # Routing is locked before Agent guards, as in cancellation and admission.
      # These reads classify an exact chain; dispatch still requires the existing
      # authority stability premise until the Agent accepts its continuation.
      def resumable_turn(execution_id)
        @persistence.transaction do |records, scope|
          state = records.handoff_states.load_locked(main_agent.agent_id)
          leaf = @persistence.handoff_leaf(execution_id, main_agent_id: main_agent.agent_id, scope: scope)
          next [state, leaf] if leaf.terminal?
          source = @persistence.agent_store.execution_identity(state.pending_source_execution_id, scope: scope) unless state.phase == "stable"
          @persistence.agent_store.guard_agents(scope, agent_ids: [main_agent.agent_id, leaf.agent_id, source&.agent_id].compact)
          require_current_turn!(state, leaf, scope)
          require_pending_target!(state, leaf, source, scope) unless state.phase == "stable"
          [state, leaf]
        end
      end

      def require_current_turn!(state, leaf, scope)
        if leaf.cancellation_requested || Array(state.metadata["cancelled_execution_ids"]).include?(leaf.execution_id)
          raise Phronomy::CancellationError, "Handoff turn was cancelled"
        end
        if state.active_agent_id != leaf.agent_id || (leaf.absent? && state.phase == "stable")
          raise Phronomy::Persistence::StateConflictError, "Handoff routing no longer owns this exact turn"
        end
        require_retention!(main_agent.agent_id, scope)
        require_retention!(leaf.agent_id, scope)
        return if leaf.absent?
        unless leaf.reservation&.correlation == handoff_owner
          raise Phronomy::Persistence::StateConflictError, "Handoff execution reservation does not match"
        end
        active = @persistence.agent_store.active_executions(agent_id: leaf.agent_id, scope: scope)
        unless active.one? && active.first.execution_id == leaf.execution_id
          raise Phronomy::Persistence::StateConflictError, "Handoff active execution does not match the requested turn"
        end
      end

      def require_pending_target!(state, leaf, source, scope)
        unless source && state.pending_target_execution_id == leaf.execution_id && source.correlation == handoff_owner
          raise Phronomy::Persistence::StateConflictError, "Handoff pending Source/Target identity mismatch"
        end
        observed = @persistence.agent_store.observe_execution(agent_id: source.agent_id, execution_id: source.execution_id, scope: scope)
        expected = {"target_agent_id" => leaf.agent_id, "target_execution_id" => leaf.execution_id,
                    "context_ref" => state.active_handoff_context_ref, "owner_key" => "handoff:#{main_agent.agent_id}"}
        unless observed.status == :handed_off && observed.transfer_receipt == expected && state.metadata["source_agent_id"] == source.agent_id
          raise Phronomy::Persistence::StateConflictError, "Handoff transfer receipt no longer matches pending routing"
        end
        require_target_definition!(agent_for(leaf.agent_id), source.agent_id, state)
        require_retention!(source.agent_id, scope, execution_id: source.execution_id)
        require_retention!(leaf.agent_id, scope, execution_id: leaf.execution_id)
      end

      def require_retention!(agent_id, scope, execution_id: nil)
        references = @persistence.agent_store.retained_references(agent_id: agent_id, scope: scope)
        unless references.any? { |reference| reference.owner_key == "handoff:#{main_agent.agent_id}" && (!execution_id || reference.execution_id == execution_id) }
          raise Phronomy::Persistence::StateConflictError, "Handoff no longer retains this execution"
        end
      end

      def require_dispatch_recovery_resolved!(active, execution_id)
        recovery = active.pending_dispatch_recovery(execution_id: execution_id)
        return unless recovery
        raise Phronomy::ExecutionRehydrationRequiredError,
          "Agent #{active.agent_id.inspect} execution #{execution_id.inspect} retains dispatch recovery #{recovery.recovery_id.inspect}; " \
          "use pending_dispatch_recovery and explicit Agent reconciliation before Handoff resume"
      end

      def load_state
        state = @persistence.handoff_states.load(main_agent.agent_id)
        return state if state
        now = Time.now.utc.iso8601(6)
        initial = HandoffState.new(main_agent_id: main_agent.agent_id, handoff_revision: 1,
          active_agent_id: main_agent.agent_id, active_handoff_context_ref: nil, phase: "stable",
          pending_source_execution_id: nil, pending_target_execution_id: nil,
          created_at: now, updated_at: now, metadata: {"retained_agent_ids" => [main_agent.agent_id]})
        @persistence.transaction do |records, scope|
          @persistence.agent_store.retain(Phronomy::Agent::Retention.new(agent_id: main_agent.agent_id, owner_key: "handoff:#{main_agent.agent_id}"), scope: scope)
          records.handoff_states.save(main_agent.agent_id, expected_revision: nil, state: initial)
        end
      rescue => error
        confirmed = @persistence.handoff_states.load(main_agent.agent_id)
        raise error unless confirmed
        confirmed
      end
    end
  end
end
