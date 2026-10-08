# frozen_string_literal: true

# Global configuration access, replacement, and scoped overrides.
# Explicitly loaded by the application entry point; not a common definition.
module Phronomy
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset_configuration!
      @configuration = Configuration.new
    end

    def with_configuration
      original = @configuration&.dup
      yield configuration
    ensure
      @configuration = original
    end
  end
end

# The provider yields only the Engine-facing value object, never Configuration.
# It is intentionally lazy and follows reset_configuration!/with_configuration.
Phronomy::RuntimeSettings.install_provider { Phronomy.configuration.__runtime_settings }

# Domain accessors are lazy too. Each returns only the owning domain's values
# or operation, never the application Configuration or a captured snapshot.
Phronomy::Agent::Settings.install_provider { Phronomy.configuration.__agent_settings }
Phronomy::WorkflowSettings.install_provider { Phronomy.configuration.__workflow_settings }
Phronomy::Tool::Settings.install_provider { Phronomy.configuration.__tool_settings }
Phronomy::Tracing::Settings.install_provider { Phronomy.configuration.__tracing_settings }
Phronomy::MultiAgent::Store.install_configured_provider { Phronomy.configuration.multi_agent_store }
