# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Configuration do
  after { Phronomy.reset_configuration! }

  describe "defaults" do
    subject(:config) { described_class.new }

    it "defaults recursion_limit to 25" do
      expect(config.recursion_limit).to eq(25)
    end

    it "defaults default_model to nil" do
      expect(config.default_model).to be_nil
    end

    it "defaults default_embedding_model to nil" do
      expect(config.default_embedding_model).to be_nil
    end

    it "defaults tracer to a NullTracer" do
      expect(config.tracer).to be_a(Phronomy::Tracing::NullTracer)
    end

    it "defaults trace_pii to false" do
      expect(config.trace_pii).to be false
    end

    it "defaults persistence to nil and no longer exposes state_store" do
      expect(config.persistence).to be_nil
      expect(config).not_to respond_to(:state_store)
      expect(config).not_to respond_to(:state_store=)
    end

    it "EventLoop is always active (no event_loop toggle)" do
      expect(config).not_to respond_to(:event_loop)
    end
  end

  describe "reading and writing settings" do
    subject(:config) { described_class.new }

    it "sets default_model" do
      config.default_model = "gpt-4o"
      expect(config.default_model).to eq("gpt-4o")
    end

    it "changes recursion_limit" do
      config.recursion_limit = 50
      expect(config.recursion_limit).to eq(50)
    end

    it "sets the unified Persistence backend" do
      persistence = Phronomy::Persistence::InMemory.new
      config.persistence = persistence
      expect(config.persistence).to be(persistence)
    end
  end
end

RSpec.describe "Phronomy.configure" do
  after { Phronomy.reset_configuration! }

  it "changes configuration with a block" do
    Phronomy.configure do |c|
      c.default_model = "claude-3-5-sonnet-20241022"
      c.recursion_limit = 50
    end

    expect(Phronomy.configuration.default_model).to eq("claude-3-5-sonnet-20241022")
    expect(Phronomy.configuration.recursion_limit).to eq(50)
  end

  it "returns the same Configuration instance each time" do
    config1 = Phronomy.configuration
    config2 = Phronomy.configuration
    expect(config1).to be(config2)
  end

  it "resets to defaults with reset_configuration!" do
    Phronomy.configure { |c| c.default_model = "gpt-4o" }
    Phronomy.reset_configuration!
    expect(Phronomy.configuration.default_model).to be_nil
  end

  it "uses the global Persistence for Agents that do not inject another backend" do
    persistence = Phronomy::Persistence::InMemory.new
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "global-persistence-agent", version: 1
    end
    Phronomy.configure { |c| c.persistence = persistence }

    expect(klass.new.persistence).to be(persistence)
  end

  it "keeps an explicitly injected Agent Persistence ahead of the global backend" do
    global = Phronomy::Persistence::InMemory.new
    explicit = Phronomy::Persistence::InMemory.new
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "explicit-persistence-agent", version: 1
    end
    Phronomy.configure { |c| c.persistence = global }

    expect(klass.new(persistence: explicit).persistence).to be(explicit)
  end

  # Regression test for Issue #104: trace_pii defaults to true — PII is forwarded to tracers without explicit opt-in
  it "defaults trace_pii to false for secure-by-default behaviour (Issue #104)" do
    config = Phronomy::Configuration.new
    expect(config.trace_pii).to be false
  end
end
