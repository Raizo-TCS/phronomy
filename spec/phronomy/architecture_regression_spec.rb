# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "EventLoop-first architecture regression guards" do
  it "keeps Testing helpers out of the general public API compatibility snapshot" do
    path = File.expand_path("../fixtures/api_snapshot.json", __dir__)
    names = JSON.parse(File.read(path)).map { |entry| entry.fetch("name") }

    expect(names.grep(/\APhronomy::Testing::/)).to be_empty
  end

  it "keeps active README guidance free of removed scheduler runtime APIs" do
    readme = File.read(File.expand_path("../../README.md", __dir__))

    expect(readme).not_to include("Phronomy::Eval::")
    expect(readme).not_to include("Runtime#yield")
    expect(readme).not_to include("Runtime#yield_if_needed")
    expect(readme).not_to include("c.runtime_backend")
    expect(readme).not_to include("Configuration#runtime_backend")
    expect(readme).not_to match(/runtime_backend\s*=\s*:/)
    expect(readme).not_to include("FakeScheduler")
    expect(readme).not_to include("FiberBackend")
    expect(readme).not_to include("ThreadBackend")
    expect(readme).not_to include("Runtime.in_scheduler_context?")
  end

  it "keeps ADR-010 aligned with the EventLoop/FSMSession control plane" do
    adr = File.read(
      File.expand_path("../../docs/decisions/010-cooperative-first-concurrency.md", __dir__)
    )

    expect(adr).to include("EventLoop")
    expect(adr).to include("FSMSession")
    expect(adr).to include("BlockingAdapterPool")
    expect(adr).to include("Task is a completion handle")
    expect(adr).to include("Production Fiber execution is not part of the architecture")
    expect(adr).not_to include("Runtime.instance.spawn(name:")
  end

  it "does not create per-child Threads in the dispatch_parallel benchmark" do
    benchmark = File.read(File.expand_path("../../benchmark/bench_regression.rb", __dir__))
    dispatch_section = benchmark
      .split("Target 4: Orchestrator#dispatch_parallel", 2)
      .fetch(1)
      .split("Target 5: CancellationToken#cancelled?", 2)
      .first

    expect(dispatch_section).not_to include("Thread.new")
  end
end
