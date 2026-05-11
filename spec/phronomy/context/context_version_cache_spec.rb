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

  # Regression test for Issue #55:
  # ContextVersionCache#update is not thread-safe: non-atomic state updates allow
  # a concurrent reader to observe a partially-updated state where fingerprint is
  # new but system_text is still nil.
  #
  # On MRI Ruby the GVL makes this race hard to trigger deterministically, so the
  # test uses direct instance-variable manipulation to simulate the exact interleaving
  # that a concurrent thread would see between the three assignments in #update.
  # On JRuby / TruffleRuby this race is easily reproducible without simulation.
  describe "#update thread-safety (Issue #55)" do
    it "never exposes a state where fingerprint is set but system_text is nil" do
      # Simulate what a concurrent reader would see if it reads between
      # assignment 1 (@fingerprint = fingerprint) and assignment 2 (@system_text = ...)
      # of ContextVersionCache#update.
      cache.instance_variable_set(:@fingerprint, "new_fp")
      # system_text has NOT been assigned yet (simulates the race window).

      # After assignment 1 only: fingerprint is "new_fp" but system_text is still nil.
      # valid?("new_fp") would return true here because fingerprint matches.
      # Then cache.system_text returns nil → system prompt is silently dropped.
      #
      # A thread-safe implementation must prevent this partially-updated state
      # from being visible to any reader.
      if cache.valid?("new_fp")
        # Inconsistency: fingerprint says "up-to-date" but system_text is nil.
        expect(cache.system_text).not_to be_nil,
          "fingerprint is set to 'new_fp' but system_text is nil — " \
          "partial state is visible. ContextVersionCache#update must be atomic."
      end
      # If valid? returns false (the cache rejects the new fingerprint while
      # system_text is nil), the test passes — the inconsistency is not exposed.
    end

    it "maintains consistent state when update is called from multiple threads" do
      # Run concurrent updates and verify that at no point is fingerprint set
      # without system_text being set in the same atomic operation.
      inconsistencies = []
      threads = 10.times.map do |i|
        Thread.new do
          cache.update(fingerprint: "fp#{i}", system_text: "text#{i}")
          # Immediately read back: fingerprint and system_text must be consistent.
          fp = cache.fingerprint
          st = cache.system_text
          if fp && st.nil?
            inconsistencies << "fingerprint=#{fp.inspect} but system_text=nil"
          end
        end
      end
      threads.each(&:join)

      # On MRI this test likely passes due to the GVL, but documents the
      # intended contract. On JRuby / TruffleRuby it would reliably catch
      # the race. See Issue #55.
      expect(inconsistencies).to be_empty,
        "Detected partial state during concurrent updates: #{inconsistencies.first}"
    end
  end
end
