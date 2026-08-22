# frozen_string_literal: true

module Phronomy
  module MultiAgent
    class Runner
      MAX_HANDOFFS = 20

      attr_reader :main_agent, :handoffs

      # @api public
      def initialize(main_agent:, handoffs: [])
        @main_agent = main_agent
        @handoffs = Array(handoffs).freeze
        @coordinator = Coordinator.attach(
          main_agent: main_agent,
          handoffs: @handoffs
        )
      end

      # @api public
      def invoke(input, config: {})
        @coordinator = Coordinator.attach(
          main_agent: @main_agent,
          handoffs: @handoffs
        )
        runtime = Phronomy::Runtime.instance
        runtime.__admit_multi_agent(@coordinator)
        handoffs_taken = 0
        current_input = input

        loop do
          state = @coordinator.snapshot
          active_agent = state.active_agent
          bindings = @coordinator.outgoing_bindings(active_agent)
          result = active_agent.invoke(
            current_input,
            config: config.merge(
              phronomy_handoff_bindings: bindings,
              phronomy_handoff_context: state.active_handoff_context
            )
          )

          request = result[:handoff_request]
          return public_result(result, active_agent) unless request

          if handoffs_taken >= MAX_HANDOFFS
            raise Phronomy::HandoffError,
              "Exceeded maximum Handoffs (#{MAX_HANDOFFS}) in one user turn"
          end

          manifest = result.fetch(:_phronomy_handoff_manifest)
          context = HandoffProjection.new.build(
            request: request,
            manifest: manifest,
            persistence: active_agent.persistence,
            source_agent: active_agent
          )
          @coordinator.transition!(request, context)
          current_input = request.responsibility
          handoffs_taken += 1
        end
      ensure
        runtime&.__release_multi_agent(@coordinator) if defined?(@coordinator)
      end

      private

      def public_result(result, agent)
        result.reject { |key, _| key.to_s.start_with?("_phronomy_") }
          .reject { |key, _| key == :handoff_request }
          .merge(agent: agent)
      end
    end
  end
end
