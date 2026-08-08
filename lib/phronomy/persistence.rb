# frozen_string_literal: true

module Phronomy
  class Persistence
    class ConflictError < Phronomy::Error; end
    class NotFoundError < Phronomy::Error; end
    class UnsupportedBackendError < Phronomy::Error; end

    attr_reader :contents, :agents, :journals, :executions, :activations

    def initialize(contents:, agents:, journals:, executions:, activations:)
      @contents = contents
      @agents = agents
      @journals = journals
      @executions = executions
      @activations = activations
      validate_capabilities!
    end

    def capabilities
      {atomic_all: false, atomic_admission: false}.freeze
    end

    def transaction
      raise UnsupportedBackendError, "#{self.class} does not provide atomic_all"
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
