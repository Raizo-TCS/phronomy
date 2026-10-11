# frozen_string_literal: true

require_relative "../persistence/errors"

module Phronomy
  # Only the requested Agent root is absent, not one of its referenced records.
  # @api public
  class AgentNotFoundError < Phronomy::Persistence::NotFoundError
    attr_reader :agent_id

    def initialize(agent_id:)
      @agent_id = agent_id.to_s.dup.freeze
      super("Agent not found: #{@agent_id}", code: "agent.not_found")
    end
  end
end
