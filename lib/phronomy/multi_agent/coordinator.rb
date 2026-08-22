# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class Coordinator
      ATTACH_MUTEX = Mutex.new
      private_constant :ATTACH_MUTEX

      ApplyHandoffCommand = Data.define(:coordinator, :request, :context, :completion)

      attr_reader :main_agent, :handoffs

      def self.attach(main_agent:, handoffs:)
        unless main_agent.is_a?(Phronomy::Agent::Base)
          raise ArgumentError, "main_agent must be a Phronomy::Agent::Base"
        end
        normalized = Array(handoffs).freeze

        ATTACH_MUTEX.synchronize do
          existing = main_agent.instance_variable_get(:@_phronomy_multi_agent_coordinator)
          if existing&.runtime_current?
            existing.assert_compatible!(normalized)
            return existing
          end

          created = new(main_agent: main_agent, handoffs: normalized)
          main_agent.instance_variable_set(:@_phronomy_multi_agent_coordinator, created)
          created
        end
      end

      def initialize(main_agent:, handoffs:)
        @main_agent = main_agent
        @handoffs = Array(handoffs).freeze
        @runtime = Phronomy::Runtime.instance
        validate_graph!
        @bindings_by_source = build_bindings
        @state_mutex = Mutex.new
        @state = CoordinationState.new(active_agent: main_agent)
      end

      def runtime_current?
        Phronomy::Runtime.instance.equal?(@runtime)
      end

      def snapshot
        unless runtime_current?
          raise Phronomy::RuntimeShutdownError,
            "Multi-Agent coordination state belongs to a previous Runtime"
        end
        @state_mutex.synchronize { @state }
      end

      def outgoing_bindings(agent)
        @bindings_by_source.fetch(agent.object_id, []).freeze
      end

      def transition!(request, context)
        completion = Phronomy::Task.deferred(name: "multi-agent-handoff")
        command = ApplyHandoffCommand.new(
          coordinator: self,
          request: request,
          context: context,
          completion: completion
        )
        posted = Phronomy::Runtime.instance.event_loop.post(
          Phronomy::Event.new(
            type: :agent_terminal_ready,
            target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
            payload: {command: command}
          )
        )
        unless posted
          completion.fail(
            Phronomy::RuntimeShutdownError.new(
              "EventLoop is not accepting Multi-Agent Handoff transitions"
            )
          )
        end
        completion.wait_result
      end

      # @api private
      def deliver_on_event_loop(command)
        runtime = Phronomy::Runtime.instance
        unless runtime.event_loop.current?
          raise Phronomy::Error,
            "Multi-Agent coordination state may only be mutated on EventLoop"
        end

        request = command.request
        context = command.context
        current = snapshot
        unless request.handoff.source_agent.equal?(current.active_agent)
          raise Phronomy::HandoffError,
            "Handoff source is no longer the active Agent"
        end

        next_state = CoordinationState.new(
          active_agent: request.handoff.target_agent,
          active_handoff_context: context
        )
        @state_mutex.synchronize { @state = next_state }
        command.completion.complete(next_state)
      rescue => error
        command.completion.fail(error)
      end

      def assert_compatible!(handoffs)
        incoming = graph_signature(handoffs)
        current = graph_signature(@handoffs)
        return true if incoming == current

        raise Phronomy::ConfigurationError,
          "a MultiAgent::Runner for this main Agent already exists with a different Handoff graph"
      end

      private

      def validate_graph!
        unless @handoffs.all? { |handoff| handoff.is_a?(Handoff) }
          raise ArgumentError, "handoffs must contain only MultiAgent::Handoff values"
        end

        duplicates = @handoffs.group_by do |handoff|
          [handoff.source_agent.object_id, handoff.target_agent.object_id]
        end.select { |_key, values| values.length > 1 }
        unless duplicates.empty?
          raise ArgumentError, "duplicate Source → Target Handoff edges are not allowed"
        end
      end

      def build_bindings
        @handoffs.group_by(&:source_agent).to_h do |source, edges|
          [
            source.object_id,
            edges.map { |handoff| HandoffCapabilityFactory.build(handoff) }.freeze
          ]
        end.freeze
      end

      def graph_signature(handoffs)
        Array(handoffs).map do |handoff|
          [
            handoff.source_agent.object_id,
            handoff.target_agent.object_id,
            handoff.policy.to_h,
            handoff.description
          ]
        end.sort_by { |row| [row[0], row[1], row[3]] }
      end
    end
  end
end
