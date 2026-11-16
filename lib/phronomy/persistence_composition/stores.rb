# frozen_string_literal: true

module Phronomy
  module PersistenceComposition
    # The application's construction result, not an execution or query facade.
    # Pass only the corresponding domain store to each domain's API.
    Stores = Data.define(:coordinator, :agent, :multi_agent, :workflow)

    # Canonical declarations for a backend supplied to .build. This frozen list
    # preserves Resource identity without constructing stores, a backend or Runtime.
    # @return [Array<Storage::Resource>] the complete domain and content catalog
    # @api public
    def self.resources = StorageSchema.resources

    # Canonical declarations for a backend supplied to .agent. This frozen list
    # includes Agent and content resources without loading Team or Workflow schemas.
    # @return [Array<Storage::Resource>] the Agent and content catalog
    # @api public
    def self.agent_resources = StorageSchema.agent_resources

    # An ordinary Agent needs only its own records and content. Do not load or
    # instantiate Team/Workflow implementations merely to construct an Agent.
    def self.agent(backend: nil)
      resources = agent_resources
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
      multi_agent = Phronomy::MultiAgent::Store.new(coordinator: coordinator, records: Phronomy::MultiAgent::Persistence::Records, agent_store: agent)
      workflow = coordinator.bind(Phronomy::Workflow::Persistence::StateRepository)
      Stores.new(coordinator: coordinator, agent: agent, multi_agent: multi_agent, workflow: workflow)
    end

    def self.in_memory
      build(backend: Phronomy::Storage::Backends::InMemory.new(resources: resources))
    end
  end
end
