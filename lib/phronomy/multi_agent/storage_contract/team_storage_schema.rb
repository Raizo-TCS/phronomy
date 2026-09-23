# frozen_string_literal: true

module Phronomy
  # Domain-owned Team metadata, independent of coordination runtime loading.
  # @api private
  module TeamStorageSchema
    ROOTS = Phronomy::Storage::Resource.new(id: "team.roots", kind: :records,
      guard: {resource: "team.roots", via: :key})
    EXECUTIONS = Phronomy::Storage::Resource.new(id: "team.executions", kind: :records,
      attributes: {owner: :string, active: :boolean}, immutable_attributes: [:owner],
      indexes: {owner: [:owner], owner_active: [:owner, :active]},
      unique: [{name: :one_active_owner, fields: [:owner], where: {active: true}}],
      guard: {resource: ROOTS.id, via: :owner})
  end
end
