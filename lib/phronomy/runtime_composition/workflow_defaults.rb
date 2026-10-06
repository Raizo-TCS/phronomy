# frozen_string_literal: true

# Install a lazy provider without creating a Runtime or execution registry.
Phronomy::WorkflowExecutionEnvironment.install_provider(-> { Phronomy::WorkflowEngineEnvironment.new })
