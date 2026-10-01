# frozen_string_literal: true

module Phronomy
  module Agent
    module Persistence
      # Domain-owned metadata; storage never interprets the record payload.
      # @api private
      module StorageSchema
        ROOTS = Phronomy::Storage::Resource.new(id: "agent.roots", kind: :records,
          guard: {resource: "agent.roots", via: :key})
        EXECUTIONS = Phronomy::Storage::Resource.new(id: "agent.executions", kind: :records,
          attributes: {owner: :string, active: :boolean}, immutable_attributes: [:owner],
          indexes: {owner: [:owner], owner_active: [:owner, :active]},
          unique: [{name: :one_active_owner, fields: [:owner], where: {active: true}}],
          guard: {resource: ROOTS.id, via: :owner})

        JOURNAL = Phronomy::Storage::Resource.new(id: "agent.journal", kind: :streams,
          guard: {resource: ROOTS.id, via: :stream})
        CANCELLATIONS = Phronomy::Storage::Resource.new(id: "agent.cancellations", kind: :records,
          attributes: {owner: :string}, immutable_attributes: [:owner], indexes: {owner: [:owner]},
          guard: {resource: ROOTS.id, via: :owner})
        RETENTIONS = Phronomy::Storage::Resource.new(id: "agent.retentions", kind: :records,
          attributes: {owner: :string, holder: :string}, immutable_attributes: [:owner, :holder],
          indexes: {owner: [:owner], holder: [:holder]},
          guard: {resource: ROOTS.id, via: :owner})
      end
    end
  end
end
