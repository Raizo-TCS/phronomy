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

  config.before(:suite) do
    RubyLLM.configure do |c|
      c.openai_api_base = LM_STUDIO_API_BASE
      c.openai_api_key = LM_STUDIO_API_KEY
      c.request_timeout = 60
    end
    # default_model is intentionally left nil so that RubyLLM.chat() is called
    # without a model argument. LM Studio ignores the model name and serves
    # whatever is currently loaded, so this is safe.
    Phronomy.reset_configuration!
  end
end
