# frozen_string_literal: true

module Phronomy
  module PersistenceComposition
    # One composition catalog, supplied to a neutral storage driver.
    # @api private
    module StorageSchema
      def self.validate!(view)
        resources.each { |resource| view.public_send(resource.kind, resource) }
      end

      def self.resources
        (agent_resources + [Phronomy::MultiAgent::Persistence::StorageSchema::ROOTS,
          Phronomy::MultiAgent::Persistence::StorageSchema::EXECUTIONS,
          Phronomy::Workflow::Persistence::StorageSchema::STATES]).freeze
      end

      def self.agent_resources
        [Agent::Persistence::StorageSchema::ROOTS,
          Agent::Persistence::StorageSchema::EXECUTIONS,
          Agent::Persistence::StorageSchema::JOURNAL,
          Agent::Persistence::StorageSchema::HANDOFF_STATES,
          ContentStore::StorageSchema::CONTENTS].freeze
      end
    end
  end
end
