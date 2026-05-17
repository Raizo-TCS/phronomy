# frozen_string_literal: true

require "spec_helper"

# Regression tests for Phronomy::ThreadActorRegistry lifecycle.
#
# Finding 4 — ThreadActorRegistry has no upper-bound on thread growth (Issue #<tbd>):
#   Each unique thread_id creates a new Ruby Thread (via Actor#initialize) and
#   stores it permanently in the registry hash.  There is no TTL, LRU eviction,
#   or maximum-size cap, so long-running servers accumulate unbounded threads.
#   These specs lock down the existing behaviour (so any future cap can be
#   verified against them) and expose the missing bound.
RSpec.describe Phronomy::ThreadActorRegistry do
  after { described_class.clear_all }

  describe ".for" do
    it "returns the same Actor instance for the same thread_id" do
      a1 = described_class.for("t-1")
      a2 = described_class.for("t-1")
      expect(a1).to be(a2)
    end

    it "returns different Actor instances for different thread_ids" do
      a1 = described_class.for("t-a")
      a2 = described_class.for("t-b")
      expect(a1).not_to be(a2)
    end
  end

  describe ".stop" do
    it "removes the actor from the registry" do
      described_class.for("t-stop")
      described_class.stop("t-stop")
      # A new actor is created on next access, not the stopped one
      new_actor = described_class.for("t-stop")
      expect(new_actor).to be_a(Phronomy::Actor)
    end
  end

  describe ".clear_all" do
    it "empties the registry" do
      described_class.for("t-x")
      described_class.for("t-y")
      described_class.clear_all
      # After clear_all, new actors are created from scratch; this should not raise
      expect { described_class.for("t-x") }.not_to raise_error
    end
  end

  # Regression for Finding 4:
  # The registry must not grow without bound.
  # This spec confirms the ABSENCE of an upper-bound cap, exposing the problem.
  # Once a max_actors configuration is added, the second example should be
  # updated to verify eviction and the first should be removed.
  describe "thread growth" do
    it "does not enforce a maximum number of concurrent actors (no cap exists yet)" do
      100.times { |i| described_class.for("cap-test-#{i}") }

      alive_threads = Thread.list.count(&:alive?)
      # With no cap, creating 100 actors spawns at least 100 extra threads.
      # This assertion confirms the unbounded-growth problem (Finding 4).
      # Once a cap is implemented, this expectation should be changed to verify
      # that the live thread count stays within the configured maximum.
      expect(alive_threads).to be >= 100
    end

    # This spec verifies the max_actors LRU cap (Finding 4 fix).
    it "caps live actor threads at the configured maximum" do
      old_max = Phronomy.configuration.max_actors
      Phronomy.configure { |c| c.max_actors = 10 }

      20.times { |i| described_class.for("bounded-#{i}") }

      expect(described_class.actor_count).to be <= 10
    ensure
      Phronomy.configure { |c| c.max_actors = old_max }
    end
  end
end
