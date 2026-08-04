# frozen_string_literal: true

require "phronomy"

# Integration tests connect to LM Studio running at http://192.168.122.1:1234/v1/
# Run with: bundle exec rspec spec/integration --tag integration
#
# LM Studio must be running with the following models loaded:
#   - openai/gpt-oss-20b  (chat)

LM_STUDIO_API_BASE = "http://192.168.122.1:1234/v1"
LM_STUDIO_API_KEY = "lm-studio"
LM_STUDIO_MODEL = "openai/gpt-oss-20b"
LM_STUDIO_EMBEDDING_MODEL = "text-embedding-nomic-embed-text-v1.5"

RSpec.configure do |config|
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Abort individual integration tests that hang (e.g. LLM call never returns).
  config.around(:each, :integration) do |example|
    require "timeout"
    Timeout.timeout(90) { example.run }
  rescue Timeout::Error
    raise "Integration test timed out after 90 s: #{example.full_description}"
  end

  # WebMock (required by tracing_adapters_spec.rb) globally disables real HTTP
  # connections once loaded. Re-allow them before each example so that LM Studio
  # calls in other spec groups are not blocked. Tests that need stubs (e.g.
  # LangfuseTracer) use stub_request inside their example body, which WebMock
  # still intercepts even when allow_net_connect! is active.
  config.before(:each) do
    WebMock.allow_net_connect! if defined?(WebMock)
    # Ensure the output reserve is always set; some tests call reset_configuration!.
    Phronomy.configure { |c| c.default_output_reserve ||= 4096 }
  end

  config.before(:suite) do
    RubyLLM.configure do |c|
      c.openai_api_base = LM_STUDIO_API_BASE
      c.openai_api_key = LM_STUDIO_API_KEY
      c.request_timeout = 60
    end
    Phronomy.reset_configuration!
    # Many test agents use openai/gpt-oss-20b whose registry max_output_tokens
    # equals its context_window, making effective_input_limit = 0 without an
    # explicit reserve. Set a framework default so budget selection works.
    Phronomy.configure { |c| c.default_output_reserve = 4096 }
  end
end
