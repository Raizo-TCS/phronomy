# frozen_string_literal: true

module Phronomy
  # Orchestrates multiple agents working together on a shared set of tasks.
  #
  # Supports two execution processes:
  #   :sequential  — tasks run one after another; each agent receives the previous
  #                  agent's output as context
  #   :hierarchical — a designated `:manager` agent decides how to delegate tasks
  #                   to the other agents
  #
  # @example Sequential crew
  #   crew = Phronomy::Crew.new(
  #     agents: {
  #       researcher: ResearcherAgent.new,
  #       writer:     WriterAgent.new
  #     },
  #     tasks: [
  #       Phronomy::Task.new(description: "Research Ruby 3.4", agent_role: :researcher),
  #       Phronomy::Task.new(description: "Write a blog post", agent_role: :writer)
  #     ],
  #     process: :sequential
  #   )
  #   results = crew.kickoff(topic: "Ruby 3.4")
  class Crew
    # @param agents [Hash<Symbol, Phronomy::Agent::Base>] role => agent instance
    # @param tasks [Array<Phronomy::Task>]
    # @param process [Symbol] :sequential (default) or :hierarchical
    def initialize(agents:, tasks:, process: :sequential)
      @agents  = agents
      @tasks   = tasks
      @process = process
    end

    # Start the crew.
    #
    # @param inputs [Hash] initial context passed to every task
    # @return [Array<Hash>] array of { output:, messages: } results, one per task
    def kickoff(inputs = {})
      case @process
      when :sequential    then run_sequential(inputs)
      when :hierarchical  then run_hierarchical(inputs)
      else
        raise ArgumentError, "Unknown process type: #{@process.inspect}. Use :sequential or :hierarchical."
      end
    end

    private

    def run_sequential(inputs)
      context = inputs.dup
      results = []

      @tasks.each do |task|
        agent = @agents[task.agent_role]
        raise ArgumentError, "No agent found for role :#{task.agent_role}" unless agent

        message = task.description_with_context(context)
        result  = agent.invoke(message)
        context = context.merge(previous_output: result[:output])
        results << result
      end

      results
    end

    def run_hierarchical(inputs)
      manager = @agents[:manager]
      raise ArgumentError, "Hierarchical process requires a :manager agent" unless manager

      # Delegate to the manager with the full inputs. The manager is expected
      # to coordinate the subordinate agents autonomously via tools or graph nodes.
      [manager.invoke(inputs)]
    end
  end
end
