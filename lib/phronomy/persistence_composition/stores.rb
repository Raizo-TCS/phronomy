# frozen_string_literal: true

module Phronomy
  module PersistenceComposition
    # The application's construction result, not an execution or query facade.
    # Pass only the corresponding domain store to each domain's API.
    Stores = Data.define(:coordinator, :agent, :team, :workflow)

    # An ordinary Agent needs only its own records and content. Do not load or
    # instantiate Team/Workflow implementations merely to construct an Agent.
    def self.agent(backend: nil)
      resources = StorageSchema.agent_resources
      backend ||= Phronomy::Storage::Backends::InMemory.new(resources: resources)
      coordinator = Phronomy::Persistence.new(backend: backend)
      Phronomy::Persistence::StorageBoundary.call do
        resources.each { |resource| backend.view.public_send(resource.kind, resource) }
      end
      Phronomy::Agent::Store.new(coordinator: coordinator, records: Phronomy::Agent::Persistence::Records)
    end

    def self.build(backend:)
      coordinator = Phronomy::Persistence.new(backend: backend)
      Phronomy::Persistence::StorageBoundary.call { StorageSchema.validate!(backend.view) }
      agent = Phronomy::Agent::Store.new(coordinator: coordinator, records: Phronomy::Agent::Persistence::Records)
      team = Phronomy::MultiAgent::Store.new(coordinator: coordinator, records: Phronomy::MultiAgent::Persistence::Records, agent_store: agent)
      workflow = coordinator.bind(Phronomy::Workflow::Persistence::StateRepository)
      Stores.new(coordinator: coordinator, agent: agent, team: team, workflow: workflow)
    end

    def self.in_memory
      build(backend: Phronomy::Storage::Backends::InMemory.new(resources: StorageSchema.resources))
    end
  end
end
