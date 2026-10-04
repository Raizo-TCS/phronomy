# frozen_string_literal: true

# Select the Agent default at the application composition boundary. Binding
# does not create Persistence, global configuration, or a Runtime.
Phronomy::Agent::DefaultPersistence.install_factory(
  -> { Phronomy::PersistenceComposition.agent }
)

Phronomy::MultiAgent::TeamCoordinator.install_persistence_factory(
  -> { Phronomy::PersistenceComposition.in_memory.multi_agent }
)

Phronomy::Agent::ExecutionEnvironment.install_provider(-> { Phronomy::Agent::EngineEnvironment.new })
