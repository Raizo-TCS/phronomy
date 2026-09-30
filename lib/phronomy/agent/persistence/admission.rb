# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Storage bindings used by the Agent admission operation. No parent schema.
      # @api private
      class Admission
        attr_reader :contents, :executions, :agents

        def initialize(view)
          @contents = Phronomy::Persistence::ContentRepository.new(Phronomy::ContentStore::StoredContents.new(view))
          @executions = ExecutionRepository.new(view)
          @agents = AgentRepository.new(view)
        end
      end
    end
  end
end
