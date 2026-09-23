# frozen_string_literal: true

# Select the Agent default at the application composition boundary. Binding
# does not create Persistence, global configuration, or a Runtime.
Phronomy::Agent::DefaultPersistence.install_factory(
  -> { Phronomy::Persistence.in_memory }
)
