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
        raise Phronomy::EventLoopReentrancyError, "HandoffRunner#invoke cannot block EventLoop" if Phronomy::WaitPolicy.blocking_forbidden?
        raise Phronomy::RuntimeShutdownError, "HandoffRunner belongs to a previous Runtime" unless @environment.current?
        trace = Phronomy::Tracing::Automatic.start("multi_agent.turn", input: input, main_agent_id: main_agent.agent_id)
        error = result = nil
        config = config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new)
        @admissions.admit!(main_agent)
        admitted = true
        state = load_state
        count = 0
        loop do
          active = @agents.fetch(state.active_agent_id) { raise Phronomy::ExecutionRehydrationRequiredError, "Handoff graph lacks active Agent #{state.active_agent_id}" }
          context = state.active_handoff_context_ref && Phronomy::Agent::TransferContext.from_h(@persistence.contents.fetch_json(state.active_handoff_context_ref))
          owner = {"kind" => "handoff", "main_agent_id" => main_agent.agent_id}.freeze
          wiring = config.merge(phronomy_control_bindings: @bindings.fetch(active.agent_id, []), phronomy_transfer_context: context,
            phronomy_execution_participant: HandoffParticipant.new(persistence: @persistence, main_agent_id: main_agent.agent_id, expected_revision: state.handoff_revision),
            phronomy_reservation: owner, phronomy_admission: ReservedChildAdmission.new(persistence: @persistence, owner: owner))
          result = if state.phase == "stable"
            unfinished = @persistence.agent_store.active_executions(agent_id: active.agent_id)
            if unfinished.empty?
              active.invoke(input, config: wiring)
            else
              exact = unfinished.fetch(0)
              unless unfinished.size == 1 && exact.reservation&.correlation == owner
                raise Phronomy::Persistence::StateConflictError, "Active execution belongs to another turn"
              end
              wiring[:cancellation_token].cancel! if Array(state.metadata["cancelled_execution_ids"]).include?(exact.execution_id)
              active.resume_async(exact.execution_id, config: wiring).wait_result
            end
          else
            source = @persistence.agent_store.execution_identity(state.pending_source_execution_id)
            unless @handoffs.any? { |edge| edge.source_agent.agent_id == source.agent_id && edge.target_agent.agent_id == state.active_agent_id }
              raise Phronomy::ExecutionRehydrationRequiredError, "Handoff graph lacks committed Source/Target edge"
            end
            unless active.class.agent_definition == state.metadata.fetch("target_definition").transform_keys(&:to_sym)
              raise Phronomy::ConfigurationError, "Handoff Target definition mismatch"
            end
            wiring[:cancellation_token].cancel! if Array(state.metadata["cancelled_execution_ids"]).include?(state.pending_target_execution_id)
            reservation = Phronomy::Agent::ReservedExecution.new(agent_id: active.agent_id, execution_id: state.pending_target_execution_id, correlation: owner)
            active.start_reserved_async(reservation: reservation, input: context.responsibility, config: wiring).wait_result
          end
          observed = @persistence.agent_store.observe_execution(agent_id: active.agent_id, execution_id: result.fetch(:execution_id))
          if observed.status == :handed_off
            count += 1
            raise Phronomy::HandoffError, "Exceeded maximum Handoffs in one turn" if count > MAX_HANDOFFS
            state = @persistence.handoff_states.load(main_agent.agent_id)
            next
          end
          raise Phronomy::ExecutionRehydrationRequiredError, "Handoff requires approval or recovery" if observed.active?
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

      def cancel(execution_id)
        raise Phronomy::EventLoopReentrancyError, "HandoffRunner#cancel cannot block EventLoop" if Phronomy::WaitPolicy.blocking_forbidden?
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
        return leaf.to_result if leaf.terminal?
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
