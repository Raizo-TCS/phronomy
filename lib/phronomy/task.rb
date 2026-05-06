# frozen_string_literal: true

module Phronomy
  # Represents a single unit of work assigned to a specific agent.
  #
  # @example
  #   task = Phronomy::Task.new(
  #     description:     "Research the new features in Ruby 3.4",
  #     agent_role:      :researcher,
  #     expected_output: "A bullet-point list of new features"
  #   )
  class Task
    attr_reader :description, :agent_role, :expected_output, :context_from

    # @param description [String] what the agent should do
    # @param agent_role [Symbol] key matching an agent in the Crew's agents Hash
    # @param expected_output [String, nil] human description of the desired output
    # @param context_from [Array<Symbol>] other task roles whose output should be
    #   prepended as context (used by Crew for sequential chaining)
    def initialize(description:, agent_role:, expected_output: nil, context_from: [])
      @description     = description
      @agent_role      = agent_role
      @expected_output = expected_output
      @context_from    = Array(context_from)
    end

    # Returns the description optionally enriched with context from a previous result.
    #
    # @param context [Hash] accumulated context from prior tasks
    # @return [String]
    def description_with_context(context)
      base = description
      prev = context[:previous_output]
      base += "\n\nResult from previous step:\n#{prev}" if prev
      base
    end
  end
end
