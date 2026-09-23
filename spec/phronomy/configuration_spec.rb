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

    it "constructs fresh component defaults for every configuration" do
      other = described_class.new

      expect(other.tracer).to be_a(Phronomy::Tracing::NullTracer)
      expect(other.llm_adapter).to be_a(Phronomy::LLMAdapter::RubyLLM)
      expect(other.tracer).not_to equal(config.tracer)
      expect(other.llm_adapter).not_to equal(config.llm_adapter)
    end

    it "preserves defaults in subclasses with the inherited zero-argument constructor" do
      subclass = Class.new(described_class)
      inherited = subclass.new

      expect(inherited).to be_a(subclass)
      expect(inherited.tracer).to be_a(Phronomy::Tracing::NullTracer)
      expect(inherited.llm_adapter).to be_a(Phronomy::LLMAdapter::RubyLLM)
      expect(inherited.recursion_limit).to eq(25)
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
      persistence = Phronomy::Persistence.in_memory
      config.persistence = persistence
      expect(config.persistence).to be(persistence)
    end

    it "keeps explicitly assigned nil components instead of recreating defaults" do
      config.tracer = nil
      config.llm_adapter = nil

      expect(config.tracer).to be_nil
      expect(config.llm_adapter).to be_nil
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

  it "recreates component defaults when resetting configuration" do
    previous = Phronomy.configuration
    current = Phronomy.reset_configuration!

    expect(current).to equal(Phronomy.configuration)
    expect(current.tracer).to be_a(Phronomy::Tracing::NullTracer)
    expect(current.llm_adapter).to be_a(Phronomy::LLMAdapter::RubyLLM)
    expect(current.tracer).not_to equal(previous.tracer)
    expect(current.llm_adapter).not_to equal(previous.llm_adapter)
  end

  it "restores component identities after a scoped override raises" do
    tracer = Phronomy.configuration.tracer
    adapter = Phronomy.configuration.llm_adapter

    expect {
      Phronomy.with_configuration do |config|
        config.tracer = Object.new
        config.llm_adapter = Object.new
        raise "scope failed"
      end
    }.to raise_error("scope failed")

    expect(Phronomy.configuration.tracer).to equal(tracer)
    expect(Phronomy.configuration.llm_adapter).to equal(adapter)
  end

  it "retains configuration without constructing defaults when Runtime cleanup fails" do
    previous = Phronomy.configuration
    RSpec::Mocks.with_temporary_scope do
      allow(Phronomy::Runtime).to receive(:reset_default!).and_raise("cleanup failed")
      expect(Phronomy::Tracing::NullTracer).not_to receive(:new)
      expect(Phronomy::LLMAdapter::RubyLLM).not_to receive(:new)

      expect { Phronomy.reset_runtime!(timeout: 0) }.to raise_error("cleanup failed")
      expect(Phronomy.configuration).to equal(previous)
    end
  end

  it "uses the global Persistence for Agents that do not inject another backend" do
    persistence = Phronomy::Persistence.in_memory
    klass = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "global-persistence-agent", version: 1
    end
    Phronomy.configure { |c| c.persistence = persistence }

    expect(klass.new.persistence).to be(persistence)
  end

  it "keeps an explicitly injected Agent Persistence ahead of the global backend" do
    global = Phronomy::Persistence.in_memory
    explicit = Phronomy::Persistence.in_memory
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
