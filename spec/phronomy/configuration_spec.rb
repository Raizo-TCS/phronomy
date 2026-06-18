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

  # Regression test for Issue #104: trace_pii defaults to true — PII is forwarded to tracers without explicit opt-in
  it "defaults trace_pii to false for secure-by-default behaviour (Issue #104)" do
    config = Phronomy::Configuration.new
    expect(config.trace_pii).to be false
  end

  # Issue #313: runtime_backend configuration
  describe "runtime_backend" do
    it "defaults to :thread" do
      expect(Phronomy::Configuration.new.runtime_backend).to eq(:thread)
    end

    it "can be set to :immediate" do
      config = Phronomy::Configuration.new
      config.runtime_backend = :immediate
      expect(config.runtime_backend).to eq(:immediate)
    end

    it "can be set to :thread" do
      config = Phronomy::Configuration.new
      config.runtime_backend = :thread
      expect(config.runtime_backend).to eq(:thread)
    end

    # Issue #353: :fiber must remain experimental opt-in; :thread is the production default
    it "does not default to :fiber (fiber backend is experimental opt-in only)" do
      expect(Phronomy::Configuration.new.runtime_backend).not_to eq(:fiber)
    end

    it "can be opted in to :fiber explicitly" do
      config = Phronomy::Configuration.new
      config.runtime_backend = :fiber
      expect(config.runtime_backend).to eq(:fiber)
    end
  end

  # Issue #312: strict_runtime_guards configuration
  describe "strict_runtime_guards" do
    it "defaults to false" do
      expect(Phronomy::Configuration.new.strict_runtime_guards).to be(false)
    end

    it "can be set to true" do
      config = Phronomy::Configuration.new
      config.strict_runtime_guards = true
      expect(config.strict_runtime_guards).to be(true)
    end
  end
end
