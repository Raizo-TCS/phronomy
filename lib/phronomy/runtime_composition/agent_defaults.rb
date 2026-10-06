# frozen_string_literal: true

# Select the Agent default at the application composition boundary. Binding
# does not create Persistence, global configuration, or a Runtime.
Phronomy::Agent::Base.context_policy(Phronomy::Context::DefaultPolicy.instance)

Phronomy::Agent::DefaultPersistence.install_factory(
  -> { Phronomy::PersistenceComposition.agent }
)

Phronomy::Agent::ExecutionEnvironment.install_provider(-> { Phronomy::Agent::EngineEnvironment.new })
