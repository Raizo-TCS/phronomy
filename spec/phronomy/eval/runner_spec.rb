# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Eval::Runner do
  let(:dataset) do
    Phronomy::Eval::Dataset.from_array([
      {input: "2+2", expected: "4"},
      {input: "3+3", expected: "6"}
    ])
  end

  describe "#run with a plain-string callable" do
    let(:callable) { ->(input) { input.gsub(/\d+\+\d+/) { |m| eval(m).to_s } } } # rubocop:disable Security/Eval

    it "returns one EvalResult per EvalCase" do
      results = described_class.new.run(dataset, callable)
      expect(results.size).to eq(2)
    end

    it "stores the actual output" do
      results = described_class.new.run(dataset, callable)
      expect(results.first.actual).to eq("4")
    end

    it "scores using ExactMatch by default" do
      results = described_class.new.run(dataset, callable)
      expect(results.all?(&:pass?)).to be true
    end

    it "sets usage to nil when callable returns a String" do
      results = described_class.new.run(dataset, callable)
      expect(results.map(&:usage)).to all(be_nil)
    end

    it "records latency_ms as a non-negative number" do
      results = described_class.new.run(dataset, callable)
      expect(results).to all(satisfy { |r| r.latency_ms >= 0 })
    end
  end

  describe "#run with a Hash-returning callable" do
    let(:usage) { Phronomy::TokenUsage.new(input: 10, output: 5) }
    let(:callable) { ->(input) { {output: "4", usage: usage} } }

    it "extracts the output from :output key" do
      results = described_class.new.run(dataset, callable)
      expect(results.first.actual).to eq("4")
    end

    it "stores usage from the :usage key" do
      results = described_class.new.run(dataset, callable)
      expect(results.first.usage).to eq(usage)
    end
  end

  describe "#run with a custom scorer" do
    it "uses the provided scorer" do
      scorer = Phronomy::Eval::Scorer::IncludesScorer.new
      runner = described_class.new(scorer: scorer)
      callable = ->(_input) { "The answer is 4." }

      results = runner.run(dataset, callable)
      expect(results.first.score).to eq(1.0)  # "The answer is 4." includes "4"
      expect(results.last.score).to eq(0.0)   # does not include "6"
    end
  end

  describe "#run with a failing callable" do
    it "propagates errors from the callable" do
      callable = ->(_input) { raise "boom" }
      expect { described_class.new.run(dataset, callable) }.to raise_error(RuntimeError, "boom")
    end
  end

  # Regression tests for Issue #49: callable exceptions inside worker threads are
  # not rescued; Thread#join re-raises them in the calling thread, aborting the
  # join loop and potentially orphaning later threads in the same slice.
  describe "#run with concurrency > 1 and a failing callable (Issue #49)" do
    let(:three_case_dataset) do
      Phronomy::Eval::Dataset.from_array([
        {input: "ok1", expected: "ok1"},
        {input: "boom", expected: "x"},
        {input: "ok2", expected: "ok2"}
      ])
    end

    it "propagates errors from the callable when concurrency > 1" do
      callable = ->(input) {
        raise "concurrent boom" if input == "boom"
        input
      }
      expect {
        described_class.new.run(three_case_dataset, callable, concurrency: 3)
      }.to raise_error(RuntimeError, "concurrent boom")
    end

    # The join order for the slice is [t0(ok1), t1(boom), t2(ok2)].
    # With the buggy implementation:
    #   - t0.join: ok1 finishes immediately → "ok1" in completed
    #   - t1.join: boom re-raises → loop aborts
    #   - t2 (ok2) is NEVER joined; it is orphaned and still sleeping its 0.2s
    # Without any sleep in the assertion, completed only contains ["ok1"], so
    # the expect(...include "ok2") FAILS → bug reproduced.
    # With a correct implementation (all threads joined before re-raise),
    # ok2 is waited for, finishes after ~0.2s, and completed = ["ok1","ok2"] → PASS.
    it "joins all threads before propagating the exception (no orphaned threads)" do
      mutex = Mutex.new
      completed = []

      callable = lambda do |input|
        raise "boom" if input == "boom"
        # ok1 is fast (no sleep). ok2 takes 0.2s so it is still sleeping when
        # t1.join re-raises in the buggy implementation.
        sleep 0.2 if input == "ok2"
        mutex.synchronize { completed << input }
        input
      end

      expect {
        described_class.new.run(three_case_dataset, callable, concurrency: 3)
      }.to raise_error(RuntimeError, "boom")

      # No sleep here: if threads were properly joined before the exception
      # propagated, ok2 is already in completed. If orphaned, ok2 is still
      # sleeping its 0.2s and is absent from completed.
      expect(completed).to include("ok1", "ok2")
    end
  end

  describe "#run with a scorer that raises" do
    let(:raising_scorer) do
      scorer = double("Scorer")
      allow(scorer).to receive(:score).and_raise(RuntimeError, "LLM unavailable")
      scorer
    end

    it "captures the scorer exception in EvalResult#error instead of propagating" do
      runner = described_class.new(scorer: raising_scorer)
      callable = ->(_input) { "answer" }
      results = runner.run(dataset, callable)
      expect(results.all?(&:scorer_error?)).to be true
    end

    it "sets score to 0.0 when scorer raises" do
      runner = described_class.new(scorer: raising_scorer)
      callable = ->(_input) { "answer" }
      results = runner.run(dataset, callable)
      expect(results.map(&:score)).to all(eq(0.0))
    end

    it "stores the exception instance in error" do
      runner = described_class.new(scorer: raising_scorer)
      callable = ->(_input) { "answer" }
      results = runner.run(dataset, callable)
      expect(results.first.error).to be_a(RuntimeError)
      expect(results.first.error.message).to eq("LLM unavailable")
    end
  end
end
