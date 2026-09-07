# frozen_string_literal: true

require "time"

module Phronomy
  module Agent
    # Durable Agent-domain responsibility routing within one Persistence instance.
    # @api public
    class HandoffRunner
      MAX_HANDOFFS = 20

      # @api public
      attr_reader :main_agent, :handoffs

      # @api public
      def initialize(main_agent:, handoffs: [])
        @main_agent, @handoffs = main_agent, Array(handoffs).freeze
        @persistence = main_agent.persistence
        raise ArgumentError, "handoffs must contain Agent::Handoff" unless @handoffs.all? { |h| h.is_a?(Handoff) }
        @agents = ([main_agent] + @handoffs.flat_map { |edge| [edge.source_agent, edge.target_agent] }).uniq.to_h { |a| [a.agent_id, a] }.freeze
        unless @agents.values.all? { |a| a.persistence.equal?(@persistence) }
          raise Phronomy::ConfigurationError, "Durable Handoff graph requires one Persistence instance"
        end
        if @handoffs.group_by { |h| [h.source_agent.agent_id, h.target_agent.agent_id] }.any? { |_, edges| edges.size > 1 }
          raise ArgumentError, "Duplicate Source/Target Handoff edges"
        end
        @bindings = @handoffs.group_by { |h| h.source_agent.agent_id }.transform_values { |edges| edges.map { |h| HandoffCapabilityFactory.build(h) }.freeze }.freeze
        @runtime = Phronomy::Runtime.instance
      end

      # @api public
      def invoke(input, config: {})
        trace_handle = Phronomy::Tracing::Automatic.start("multi_agent.turn",
          input: input, main_agent_id: main_agent.agent_id,
          **main_agent.send(:_build_caller_meta, config))
        operation_error = result = nil
        if Phronomy::Runtime.in_event_loop_context?
          raise Phronomy::EventLoopReentrancyError, "HandoffRunner#invoke cannot block EventLoop"
        end
        unless Phronomy::Runtime.instance.equal?(@runtime)
          raise Phronomy::RuntimeShutdownError, "HandoffRunner belongs to a previous Runtime"
        end
        config = config.merge(cancellation_token: config[:cancellation_token] || Phronomy::Concurrency::CancellationToken.new)
        @runtime.__admit_multi_agent(main_agent)
        admitted = true
        state = load_state
        count = 0
        loop do
          active = @agents.fetch(state.active_agent_id) do
            raise Phronomy::ExecutionRehydrationRequiredError, "Handoff graph lacks active Agent #{state.active_agent_id}"
          end
          context = state.active_handoff_context_ref && HandoffContext.from_h(@persistence.contents.fetch_json(state.active_handoff_context_ref))
          wiring = config.merge(phronomy_handoff_bindings: @bindings.fetch(active.agent_id, []),
            phronomy_handoff_context: context,
            phronomy_coordination: {"kind" => "handoff", "main_agent_id" => main_agent.agent_id, "handoff_revision" => state.handoff_revision}).freeze
          active.instance_variable_set(:@_phronomy_coordination_config, wiring)
          result = if state.phase == "stable"
            unfinished = @persistence.executions.list_active(active.agent_id)
            if unfinished.empty?
              active.invoke(input, config: wiring)
            else
              exact = unfinished.fetch(0)
              unless unfinished.size == 1 && exact.metadata.dig("coordination", "main_agent_id") == main_agent.agent_id
                raise Phronomy::Persistence::ConflictError, "Active Agent execution belongs to another coordination turn"
              end
              wiring[:cancellation_token].cancel! if Array(state.metadata["cancelled_execution_ids"]).include?(exact.execution_id)
              stored_input = @persistence.contents.fetch_text(exact.metadata.fetch("current_input_ref"))
              ExactExecution.start(agent: active, execution_id: exact.execution_id, input: stored_input, config: wiring).wait_result
            end
          else
            source = @persistence.executions.load(state.pending_source_execution_id)
            unless @handoffs.any? { |edge| edge.source_agent.agent_id == source.agent_id && edge.target_agent.agent_id == state.active_agent_id }
              raise Phronomy::ExecutionRehydrationRequiredError, "Handoff graph lacks committed Source/Target edge"
            end
            definition = state.metadata.fetch("target_definition")
            unless active.class.agent_definition == definition.transform_keys(&:to_sym)
              raise Phronomy::ConfigurationError, "Handoff Target definition mismatch"
            end
            wiring[:cancellation_token].cancel! if Array(state.metadata["cancelled_execution_ids"]).include?(state.pending_target_execution_id)
            ExactExecution.start(agent: active, execution_id: state.pending_target_execution_id,
              input: context.responsibility, config: wiring).wait_result
          end
          execution = @persistence.executions.load(result.fetch(:execution_id))
          if execution.status == :handed_off
            count += 1
            raise Phronomy::HandoffError, "Exceeded maximum Handoffs in one turn" if count > MAX_HANDOFFS
            state = @persistence.handoff_states.load(main_agent.agent_id)
            next
          end
          if execution.active?
            raise Phronomy::ExecutionRehydrationRequiredError, "Handoff execution requires approval or recovery"
          end
          raise RecoverySupport.error_from_failure(result[:error]) if result[:error]
          return result.reject { |key, _| key.to_s.start_with?("_phronomy_") || key == :handoff_request }.merge(agent: active)
        end
      rescue Phronomy::CancellationError => error
        operation_error = error
        cancel(state.pending_source_execution_id) if state && state.phase != "stable"
        raise
      rescue => error
        operation_error = error
        raise
      ensure
        @runtime.__release_multi_agent(main_agent) if admitted
        Phronomy::Tracing::Automatic.finish(trace_handle, output: result && result[:output], error: operation_error)
      end

      # Durably scopes cancellation to an exact turn, including a transferred
      # Target reservation. A completed older turn never cancels a later turn.
      # @api public
      def cancel(execution_id)
        if Phronomy::Runtime.in_event_loop_context?
          raise Phronomy::EventLoopReentrancyError, "HandoffRunner#cancel cannot block EventLoop"
        end
        intended = leaf = leaf_id = nil
        begin
          @persistence.transaction do |tx|
            first = tx.executions.load(execution_id)
            unless first.metadata.dig("coordination", "main_agent_id") == main_agent.agent_id
              raise Phronomy::Persistence::ConflictError, "Execution does not belong to this Handoff anchor"
            end
            leaf = first
            leaf_id = first.execution_id
            seen = {}
            while leaf&.status == :handed_off
              raise Phronomy::Persistence::SerializationError, "Cyclic Handoff chain" if seen[leaf_id]
              seen[leaf_id] = true
              leaf_id = leaf.metadata.fetch("handoff_target_execution_id")
              begin
                leaf = tx.executions.load(leaf_id)
              rescue Phronomy::Persistence::NotFoundError
                leaf = nil
              end
            end
            next if leaf&.terminal?
            routing = tx.handoff_states.load(main_agent.agent_id)
            unless routing && (leaf ? routing.active_agent_id == leaf.agent_id : routing.pending_target_execution_id == leaf_id)
              raise Phronomy::Persistence::ConflictError, "Handoff routing no longer owns the requested turn"
            end
            ids = (Array(routing.metadata["cancelled_execution_ids"]) + [leaf_id]).uniq
            intended = routing.with(phase: leaf ? routing.phase : "stable",
              metadata: routing.metadata.merge("cancelled_execution_ids" => ids))
            tx.handoff_states.save(main_agent.agent_id, expected_revision: routing.handoff_revision, state: intended)
          end
        rescue => error
          confirmed = @persistence.handoff_states.load(main_agent.agent_id)
          raise error unless intended && confirmed && Array(confirmed.metadata["cancelled_execution_ids"]).include?(leaf_id)
        end
        return @persistence.execution_result(leaf_id) if leaf&.terminal?
        ExecutionCancellation.signal(leaf_id, leaf.agent_id) if leaf&.active?
        {execution_id: leaf_id, cancellation_requested: !leaf&.terminal?}.freeze
      end

      # Reads a specified source/Target chain without current graph continuation.
      # @api public
      def result(execution_id)
        @persistence.handoff_result(execution_id, main_agent_id: main_agent.agent_id)
      end

      private

      def load_state
        state = @persistence.handoff_states.load(main_agent.agent_id)
        return state if state
        now = Time.now.utc.iso8601(6)
        initial = HandoffState.new(main_agent_id: main_agent.agent_id, handoff_revision: 1,
          active_agent_id: main_agent.agent_id, active_handoff_context_ref: nil,
          phase: "stable", pending_source_execution_id: nil, pending_target_execution_id: nil,
          created_at: now, updated_at: now, metadata: {})
        @persistence.transaction { |tx| tx.handoff_states.save(main_agent.agent_id, expected_revision: nil, state: initial) }
      rescue => error
        confirmed = @persistence.handoff_states.load(main_agent.agent_id)
        raise error unless confirmed
        confirmed
      end
    end
  end
end
