# frozen_string_literal: true

module Phronomy
  # An old Agent reference cannot act on a later incarnation of the same ID.
  # @api public
  class AgentUnloadedError < Phronomy::Error
    attr_reader :agent_id

    def initialize(agent_id:)
      @agent_id = agent_id.to_s.dup.freeze
      super("Agent #{@agent_id.inspect} has been unloaded", code: "agent.unloaded")
    end
  end
end
