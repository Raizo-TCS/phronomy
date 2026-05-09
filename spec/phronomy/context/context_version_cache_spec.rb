# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Context::ContextVersionCache do
  subject(:cache) { described_class.new }

  def make_cache_with(fingerprint:, system_text:)
    c = described_class.new
    c.update(fingerprint: fingerprint, system_text: system_text)
    c
  end

  describe "#initialize" do
    it "starts with nil fingerprint" do
      expect(cache.fingerprint).to be_nil
    end

    it "starts with nil system_text" do
      expect(cache.system_text).to be_nil
    end

    it "starts with zero system_tokens" do
      expect(cache.system_tokens).to eq(0)
    end
  end

  describe "#valid?" do
    context "when the cache is empty (cold)" do
      it "returns false for any fingerprint" do
        expect(cache.valid?("abc123")).to be(false)
      end
    end

    context "after update" do
      before { cache.update(fingerprint: "fp1", system_text: "You are helpful.") }

      it "returns true when fingerprint matches" do
        expect(cache.valid?("fp1")).to be(true)
      end

      it "returns false when fingerprint differs" do
        expect(cache.valid?("fp2")).to be(false)
      end
    end
  end

  describe "#update" do
    before { cache.update(fingerprint: "fp-new", system_text: "System prompt text.") }

    it "stores the new fingerprint" do
      expect(cache.fingerprint).to eq("fp-new")
    end

    it "stores the system_text" do
      expect(cache.system_text).to eq("System prompt text.")
    end

    it "estimates system_tokens > 0 for non-empty text" do
      expect(cache.system_tokens).to be > 0
    end

    it "updates to zero tokens when system_text is empty" do
      cache.update(fingerprint: "fp-empty", system_text: "")
      expect(cache.system_tokens).to eq(0)
    end
  end

  describe "#reset" do
    before { cache.update(fingerprint: "fp", system_text: "Some text") }

    it "clears the fingerprint" do
      cache.reset
      expect(cache.fingerprint).to be_nil
    end

    it "clears the system_text" do
      cache.reset
      expect(cache.system_text).to be_nil
    end

    it "resets system_tokens to zero" do
      cache.reset
      expect(cache.system_tokens).to eq(0)
    end

    it "makes valid? return false afterwards" do
      cache.reset
      expect(cache.valid?("fp")).to be(false)
    end
  end

  describe "cache miss → update → hit cycle" do
    it "reflects a valid cache after update and becomes invalid after reset" do
      expect(cache.valid?("fp")).to be(false)
      cache.update(fingerprint: "fp", system_text: "text")
      expect(cache.valid?("fp")).to be(true)
      cache.reset
      expect(cache.valid?("fp")).to be(false)
    end
  end
end
