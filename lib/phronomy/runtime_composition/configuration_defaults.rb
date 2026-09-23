# frozen_string_literal: true

# Select concrete defaults at the application composition boundary. Each factory
# runs during Configuration.new, not during binding; no Runtime is started here.
# Explicitly loaded after Zeitwerk setup and before global configuration access.
Phronomy::Configuration.install_default_factories(
  tracer: -> { Phronomy::Tracing::NullTracer.new },
  llm_adapter: -> { Phronomy::LLMAdapter::RubyLLM.new }
)
