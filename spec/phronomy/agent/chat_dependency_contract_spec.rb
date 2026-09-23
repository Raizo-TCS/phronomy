# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Agent chat dependency contract" do
  around do |example|
    old_api_key = RubyLLM.config.openai_api_key
    example.run
  ensure
    RubyLLM.configure { |config| config.openai_api_key = old_api_key }
  end

  it "constructs ordinary chat without MultiAgent or the removed chat configuration API" do
    source = <<~RUBY
      require "phronomy"
      Zeitwerk::Loader.eager_load_all
      [Phronomy::Agent, Phronomy::MultiAgent].each do |namespace|
        abort "obsolete chat class remains" if namespace.const_defined?(:ParallelToolChat, false)
      end
      configuration = Phronomy.configuration
      abort "obsolete reader remains" if configuration.respond_to?(:parallel_tool_execution)
      abort "obsolete writer remains" if configuration.respond_to?(:parallel_tool_execution=)
      Phronomy.send(:remove_const, :MultiAgent)
      RubyLLM.configure { |c| c.openai_api_key = "test-api-key" }
      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "chat-dependency-contract", version: 1
      end
      chat = klass.new.send(:build_chat, model_config: {"model" => "test-model", "provider" => "openai"})
      abort "unexpected chat class" unless chat.instance_of?(RubyLLM::Chat)
      Phronomy.reset_runtime!
    RUBY
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", source
    )
    expect(status.success?).to be(true), [stdout, stderr].join("\n")
  end

  [false, true].each do |legacy_value|
    it "materializes an existing model-config record with the legacy value #{legacy_value} without rewriting it" do
      RubyLLM.configure { |config| config.openai_api_key = "test-api-key" }
      persistence = Phronomy::Persistence.in_memory
      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "legacy-chat-config-#{legacy_value}", version: 1
      end
      agent = klass.new(persistence: persistence)
      stored_config = {"model" => "test-model", "provider" => "openai", "parallel_tool_execution" => legacy_value}
      config_ref = persistence.contents.put_json(stored_config)
      manifest = Phronomy::Agent::LLMInputManifest.new(
        call_sequence: 1, call_mode: :complete, segments: [], model_config_ref: config_ref
      )
      manifest_ref = persistence.contents.put_json(manifest.to_h)
      reloaded = Phronomy::Agent::LLMInputManifest.from_h(persistence.contents.fetch_json(manifest_ref))
      projection = Phronomy::Agent::RubyLLMMaterializer.new(agent: agent, persistence: persistence)
        .materialize(manifest: reloaded, manifest_ref: manifest_ref)
      chat = agent.send(:build_chat, model_config: projection.model_config)

      expect(chat).to be_an_instance_of(RubyLLM::Chat)
      expect(chat.model.id).to eq("test-model")
      expect(persistence.contents.fetch_json(config_ref)).to eq(stored_config)
      expect(persistence.contents.put_json(reloaded.to_h)).to eq(manifest_ref)
    end
  end
end
