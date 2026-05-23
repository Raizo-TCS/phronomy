# frozen_string_literal: true

module Phronomy
  module Agent
    # Orchestrates a multi-agent conversation by routing between agents
    # based on handoff tool calls detected in each agent's conversation history.
    #
    # Runner configures handoff tools on source agent instances at construction
    # time, then coordinates invocations: after each agent turn it inspects
    # the returned messages for a handoff sentinel and routes accordingly.
    #
    # @example Linear handoff (triage → billing)
    #   triage  = TriageAgent.new
    #   billing = BillingAgent.new
    #   runner  = Phronomy::Agent::Runner.new(
    #     agents: [triage, billing],
    #     routes: { triage => [billing] }
    #   )
    #   result = runner.invoke("I need help with my invoice")
    #   puts result[:output]
    #   puts result[:agent].class  # => BillingAgent
    class Runner
      # Maximum number of agent handoffs allowed per invoke call.
      MAX_HANDOFFS = 20

      attr_reader :agents

      # @param agents [Array<Phronomy::Agent::Base>]
      #   agents managed by this runner; first element is the entry agent
      # @param routes [Hash{Phronomy::Agent::Base => Array<Phronomy::Agent::Base>}]
      #   declares which target agents each source agent may hand off to;
      #   when omitted no handoffs are configured and the entry agent handles everything
      # @api public
      def initialize(agents:, routes: {})
        @agents = Array(agents)
        raise ArgumentError, "At least one agent is required" if @agents.empty?

        @entry_agent = @agents.first
        @sentinel_map = {}
        build_handoffs(routes)
      end

      # Invokes the runner with the given input, routing between agents as needed.
      # Stops when an agent's turn produces no handoff signal, or when MAX_HANDOFFS
      # is reached (raises HandoffError in that case).
      #
      # @param input  [String, Hash] the initial user message
      # @param config [Hash] forwarded to each agent's #invoke
      # @return [Hash] { output:, messages:, usage:, agent: }
      # @raise [Phronomy::HandoffError] if more than MAX_HANDOFFS handoffs occur
      # @api public
      def invoke(input, config: {})
        current = @entry_agent
        handoffs_taken = 0

        loop do
          # Check before invoking so we raise after exactly MAX_HANDOFFS handoffs,
          # not after MAX_HANDOFFS + 1 LLM calls.
          if handoffs_taken >= MAX_HANDOFFS
            raise Phronomy::HandoffError, "Exceeded maximum handoffs (#{MAX_HANDOFFS})"
          end

          result = current.invoke(input, config: config)
          target = find_handoff_target(result[:messages])
          return result.merge(agent: current) unless target

          current = target
          handoffs_taken += 1
        end
      end

      private

      def build_handoffs(routes)
        routes.each do |source_agent, target_agents|
          Array(target_agents).each do |target_agent|
            handoff = Handoff.new(target_agent: target_agent)
            @sentinel_map[handoff.sentinel] = target_agent
            source_agent._add_handoff_tool(handoff.to_tool_class)
          end
        end
      end

      def find_handoff_target(messages)
        messages.reverse_each do |msg|
          next unless msg.role.to_sym == :tool

          content = msg.content.to_s
          next unless content.start_with?(Handoff::SENTINEL_PREFIX)

          return @sentinel_map[content]
        end
        nil
      end
    end
  end
end
