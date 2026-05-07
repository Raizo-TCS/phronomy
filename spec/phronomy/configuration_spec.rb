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

    it "defaults default_state_store to nil" do
      expect(config.default_state_store).to be_nil
    end

    it "defaults default_memory to nil" do
      expect(config.default_memory).to be_nil
    end

    it "defaults tracer to a NullTracer" do
      expect(config.tracer).to be_a(Phronomy::Tracing::NullTracer)
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

    it "sets a StateStore" do
      store = Phronomy::StateStore::InMemory.new
      config.default_state_store = store
      expect(config.default_state_store).to be(store)
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
end
