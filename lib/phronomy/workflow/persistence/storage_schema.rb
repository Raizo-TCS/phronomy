# frozen_string_literal: true

module Phronomy
  # Domain-owned Workflow metadata, loadable without the Workflow runtime.
  # @api private
  class Workflow
    module Persistence
      module StorageSchema
        STATES = Phronomy::Storage::Resource.new(id: "workflow.states", kind: :records)
      end
    end
  end
end
