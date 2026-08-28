# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "EventLoop-first architecture regression guards" do
  it "keeps Testing helpers out of the general public API compatibility snapshot" do
    path = File.expand_path("../fixtures/api_snapshot.json", __dir__)
    names = JSON.parse(File.read(path)).map { |entry| entry.fetch("name") }

    expect(names.grep(/\APhronomy::Testing::/)).to be_empty
  end

  it "keeps active README guidance free of removed runtime APIs" do
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
    expect(readme).not_to include("BlockingAdapterPool")
    expect(readme).not_to include("Runtime#blocking_io")
    expect(readme).not_to include("blocking_io_pool_size")
    expect(readme).not_to include("blocking_io_queue_size")
    expect(readme).not_to include("execution_mode :blocking_io")
    expect(readme).not_to include("execution_mode :cpu_bound")
    expect(readme).not_to include("execution_mode :external_process")
  end

  it "keeps ADR-010 aligned with the EventLoop/FSMSession/OffloadPool control plane" do
    adr = File.read(
      File.expand_path("../../docs/decisions/010-cooperative-first-concurrency.md", __dir__)
    )

    expect(adr).to include("EventLoop")
    expect(adr).to include("FSMSession")
    expect(adr).to include("OffloadPool")
    expect(adr).to include("single caller-facing completion")
    expect(adr).to include("application-owned")
    expect(adr).to include("Production Fiber execution is not part of the architecture")
    expect(adr).not_to include("Runtime.instance.spawn(name:")
    expect(adr).not_to include("BlockingAdapterPool")
  end

  it "documents Task settlement and waiter-local timeout without Thread#raise" do
    adr = File.read(
      File.expand_path("../../docs/decisions/010-cooperative-first-concurrency.md", __dir__)
    )
    cancellation = adr
      .split("## Timeout and cancellation", 2)
      .fetch(1)
      .split("## CPU-bound work", 2)
      .first

    expect(cancellation).to include("settles the caller-facing Task")
    expect(cancellation).to include("worker may continue")
    expect(cancellation).to include("`Task#wait_result(timeout:)`")
    expect(cancellation).to match(/does\s+not settle the Task/)
    expect(cancellation).to include("does not use `Thread#raise`")
    expect(cancellation).not_to include("wait_result(cancellation_token:")
  end

  it "keeps OffloadPool execution state private behind Task completion" do
    source = File.read(
      File.expand_path("../../lib/phronomy/engine/concurrency/offload_pool.rb", __dir__)
    )

    expect(source).to include("class Operation")
    expect(source).to include("private_constant :Operation")
    # ACS-16 replaced Task.deferred with the private PhysicalCompletionTask subclass.
    expect(source).to include("@task = Phronomy::Concurrency::PhysicalCompletionTask.deferred")
    expect(source).not_to include("class PendingOperation")
  end

  it "keeps FSMSession identity owned by FSMSession and out of Agent/Tool contexts" do
    fsm = File.read(
      File.expand_path("../../lib/phronomy/engine/fsm_session.rb", __dir__)
    )
    agent = File.read(
      File.expand_path("../../lib/phronomy/agent/agent_invocation.rb", __dir__)
    )
    tool = File.read(
      File.expand_path("../../lib/phronomy/agent/tool_invocation.rb", __dir__)
    )

    expect(fsm).to include("SecureRandom.uuid.to_s.freeze")
    expect(fsm).to include("fsm_session_id")
    expect(agent).not_to include("attr_reader :id")
    expect(agent).not_to include(":session_id")
    expect(tool).not_to include("parent_agent_invocation_id")
    expect(tool).not_to include(":session_id")
  end

  it "keeps synchronous VectorStore async convenience on OffloadPool" do
    source = File.read(
      File.expand_path("../../lib/phronomy/vector_store/async_backend.rb", __dir__)
    )

    expect(source).to include("Phronomy::Runtime.instance.offload.submit")
    expect(source).to include("@return [Phronomy::Task]")
    expect(source).not_to include("PendingOperation")
    expect(source).not_to include("Override to use a native async driver")
  end

  it "keeps LLMAdapter implementer methods separate from the private async bridge" do
    source = File.read(
      File.expand_path("../../lib/phronomy/llm_adapter/base.rb", __dir__)
    )

    expect(source).to match(/# @api public\n\s+def complete\(/)
    expect(source).to match(/# @api public\n\s+def stream\(/)
    expect(source).to match(/# @api private\n\s+def complete_async\(/)
    expect(source).to include("pool.submit")
    expect(source).not_to include("PendingOperation")
  end

  it "documents cumulative and active abandoned-worker metrics separately" do
    adr = File.read(
      File.expand_path("../../docs/decisions/010-cooperative-first-concurrency.md", __dir__)
    )

    expect(adr).to include("offload_pool_abandoned_total")
    expect(adr).to include("offload_pool_abandoned_active")
    expect(adr).to include("cumulative")
    expect(adr).to include("current-state")
  end

  it "keeps ADR-008 historical text but uses current terminology in its superseding decision" do
    adr = File.read(
      File.expand_path("../../docs/decisions/008-orchestrator-uses-os-threads.md", __dir__)
    )
    current_guidance = adr.split("## Superseding decision", 2).fetch(1)

    expect(adr).to include("one OS\nThread per `dispatch_parallel` child")
    expect(current_guidance).to include("OffloadPool")
    expect(current_guidance).not_to include("BlockingAdapterPool")
  end

  it "keeps the Unreleased changelog migration direction correct" do
    changelog = File.read(File.expand_path("../../CHANGELOG.md", __dir__))
    unreleased = changelog
      .split("## [Unreleased]", 2)
      .fetch(1)
      .split("\n---", 2)
      .first
    offload = unreleased
      .split("### OffloadPool execution model", 2)
      .fetch(1)
      .split("### EventLoop-first runtime cleanup", 2)
      .first

    changed = offload.split("#### Changed", 2).fetch(1).split("#### Removed", 2).first
    removed = offload.split("#### Removed", 2).fetch(1)

    expect(changed).to include("`BlockingAdapterPool`")
    expect(changed).to include("`OffloadPool`")
    expect(changed).to include("`Runtime#blocking_io`")
    expect(changed).to include("`Runtime#offload`")
    expect(changed).to include("`offload_pool_abandoned_total`")
    expect(changed).to include("`offload_pool_abandoned_active`")
    expect(changed).not_to include("Renamed `OffloadPool` to `OffloadPool`")

    expect(removed).to include("`:blocking_io`")
    expect(removed).to include("`:cpu_bound`")
    expect(removed).to include("`:external_process`")
    expect(removed).to include("`Runtime#blocking_io`")
    expect(removed).to include("`blocking_io_pool_size`")
    expect(removed).to include("`blocking_io_queue_size`")
    expect(removed).to include("`PendingOperation#blocking_wait`")
    expect(removed).to include("`cancellation_token:`")
    expect(removed).not_to include("`Runtime#offload`")
    expect(removed).not_to include("`offload_pool_size`")
    expect(removed).not_to include("`offload_queue_size`")
  end

  it "keeps long-form documentation and historical changelog out of the entry files" do
    root = File.expand_path("../..", __dir__)
    readme = File.read(File.join(root, "README.md"))
    changelog = File.read(File.join(root, "CHANGELOG.md"))
    archive = File.read(File.join(root, "docs/changelog/0.14-and-earlier.md"))

    expect(readme).to include("docs/getting-started.md")
    expect(readme).to include("docs/features.md")
    expect(readme).to include("docs/runtime-and-concurrency.md")
    expect(readme).to include("docs/migrations/0.15.md")
    expect(readme).to include("docs/migrations/0.16.md")

    expect(changelog).to include("docs/changelog/0.14-and-earlier.md")
    expect(changelog).to include("## [Unreleased]")
    expect(changelog).to include("## [0.16.0]")
    expect(changelog).not_to include("## [0.14.0]")

    expect(archive).to include("## [0.14.0]")
    expect(archive).to include("## [0.2.0]")
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
  it "keeps architecture documentation in the canonical current/archive lifecycle" do
    root = File.expand_path("../..", __dir__)

    expect(File).to exist(File.join(root, "docs/architecture.md"))
    expect(File).to exist(File.join(root, "docs/architecture/context-management.md"))
    expect(File).to exist(File.join(root, "docs/architecture/security-boundaries.md"))
    expect(File).to exist(File.join(root, "docs/architecture/tracing.md"))
    expect(File).to exist(File.join(root, "docs/architecture/multi-agent-handoff.md"))
    expect(File).to exist(File.join(root, "docs/architecture/persistence.md"))
    expect(Dir.glob(File.join(root, "spec/design/**/*"), File::FNM_DOTMATCH)).to eq([])
  end
end
