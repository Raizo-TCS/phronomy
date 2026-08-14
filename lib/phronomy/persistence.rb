# frozen_string_literal: true

module Phronomy
  class Persistence
    class ConflictError < Phronomy::Error; end
    class NotFoundError < Phronomy::Error; end
    class UnsupportedBackendError < Phronomy::Error; end

    attr_reader :contents, :agents, :journals, :executions, :workflow_states

    def initialize(contents:, agents:, journals:, executions:, workflow_states:)
      @contents = contents
      @agents = agents
      @journals = journals
      @executions = executions
      @workflow_states = workflow_states
      validate_capabilities!
    end

    def capabilities
      {atomic_all: false, atomic_admission: false}.freeze
    end

    def transaction
      raise UnsupportedBackendError, "#{self.class} does not provide atomic_all"
    end

    # Verifies that a live Agent still owns the durable base it hydrated.
    # Backends should implement this as a revision/position precondition check,
    # not as a state reload returned to the caller.
    # @api private
    def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
      raise UnsupportedBackendError,
        "#{self.class} does not provide Agent durable-watermark checks"
    end

    private

    def validate_capabilities!
      required = {atomic_all: true, atomic_admission: true}
      missing = required.reject { |key, value| capabilities[key] == value }
      return if missing.empty?

      raise UnsupportedBackendError,
        "Persistence backend lacks required capabilities: #{missing.keys.join(", ")}"
    end
  end
end
