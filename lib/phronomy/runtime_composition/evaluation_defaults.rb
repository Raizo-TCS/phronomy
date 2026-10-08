# frozen_string_literal: true

# Binding creates no client, Configuration or Runtime. Resolve the configured
# adapter for every score at the existing read point; do not cache the client.
Phronomy::Testing::Eval::Scorer::LlmJudge.install_client_factory(
  -> { Phronomy::LLMAdapter::AsyncClient.new(adapter: Phronomy.configuration.llm_adapter) }
)
