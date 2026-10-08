# frozen_string_literal: true

# Select stores and execution connections at the application composition
# boundary, without constructing either during library loading.
Phronomy::MultiAgent::TeamCoordinator.install_persistence_factory(
  -> { Phronomy::PersistenceComposition.in_memory.multi_agent }
)

Phronomy::MultiAgent::ExecutionEnvironment.install_provider(-> { Phronomy::MultiAgent::EngineEnvironment.new })
