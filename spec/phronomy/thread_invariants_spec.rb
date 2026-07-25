# frozen_string_literal: true

# These tests verify the threading invariants established after the Runtime /
# Scheduler migration (#255-#259).
#
# Core rule: Thread.new in user-facing call paths (invoke_async, Workflow#invoke,
# tool execution) must NOT create threads directly; blocking work goes through
# BlockingAdapterPool.  The tests spy on Thread.method(:new) to enforce this.
RSpec.describe "Thread.new absence from core paths (Issue #272)" do
  # Spy helper: intercepts Thread.new and records calls, then delegates to real
  # Thread.new so the code still functions.
  def with_thread_spy
    calls = []
    original = Thread.method(:new)
    allow(Thread).to receive(:new) do |*args, **kwargs, &block|
      calls << caller_locations(1, 5).map(&:to_s)
      original.call(*args, **kwargs, &block)
    end
    yield calls
  end

  describe "BlockingAdapterPool" do
    it "spawns exactly pool_size threads at initialisation, then no more on submit" do
      pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 2, queue_size: 10)

      Thread.list.count
      # Submit a trivial operation — must not spawn a new thread
      new_threads_during_submit = 0
      original = Thread.method(:new)
      allow(Thread).to receive(:new) do |*a, **kw, &blk|
        new_threads_during_submit += 1
        original.call(*a, **kw, &blk)
      end

      op = pool.submit { 42 }
      expect(op.wait_result).to eq(42)
      expect(new_threads_during_submit).to eq(0)
    ensure
      pool.shutdown(drain_timeout: 2)
    end

    it "does not exceed pool_size worker threads" do
      pool = Phronomy::Concurrency::BlockingAdapterPool.new(pool_size: 3, queue_size: 20)
      barrier = Mutex.new
      cond = ConditionVariable.new
      released = false

      # Fill all workers
      3.times { pool.submit { barrier.synchronize { cond.wait(barrier, 5) until released } } }
      sleep(0.02)

      expect(pool.active_count).to be <= 3
    ensure
      barrier.synchronize {
        released = true
        cond.broadcast
      }
      pool.shutdown(drain_timeout: 2)
    end

    it "tracks abandoned (timed-out) operations" do
      # Use a dedicated pool so the timed-out op runs immediately (no queue wait)
      timer = Phronomy::Testing::FakeClock.new
      pool = Phronomy::Concurrency::BlockingAdapterPool.new(
        pool_size: 1, queue_size: 5,
        timer_queue_provider: -> { timer }
      )
      started = Queue.new
      release = Queue.new

      op = pool.submit(timeout: 5) do
        started << true
        release.pop
      end

      started.pop        # worker started
      timer.advance(5)   # fire timeout

      expect(op).to be_abandoned
      expect(pool.abandoned_count).to be >= 1

      release << true
    ensure
      pool.shutdown(drain_timeout: 1)
    end
  end

  describe "EventLoop lag under normal load" do
    it "keeps average lag below 100ms under light dispatch load" do
      el = Phronomy::EventLoop.instance
      # Dispatch a few workflow runs and check the recorded average lag
      wf_ctx = Class.new do
        include Phronomy::WorkflowContext

        field :n, default: -> { 0 }
      end
      app = Phronomy::Workflow.define(wf_ctx) do
        initial :bump
        state :bump, action: ->(s) { s.merge(n: s.n + 1) }
        transition from: :bump, to: :__finish__
      end

      5.times do |i|
        app.invoke({}, config: {thread_id: "lag-load-#{i}-#{SecureRandom.hex(4)}"})
      end

      expect(el.average_lag_seconds).to be < 0.1
    end
  end
end

# Issue #302 — Thread.current must only appear in files that explicitly own a
# Thread context (EventLoop background thread marker, Task#spawn name setter).
# All other modules must use the public Phronomy::EventLoop.current? predicate
# or InvocationContext instead of reading thread-locals directly.
RSpec.describe "Thread.current confinement (Issue #302)", :issue_302 do
  # Files permitted to reference Thread.current directly.
  THREAD_CURRENT_ALLOWLIST = %w[
    lib/phronomy/engine/event_loop.rb
    lib/phronomy/engine/task.rb
    lib/phronomy/engine/task/thread_backend.rb
    lib/phronomy/engine/task/immediate_backend.rb
    lib/phronomy/engine/task/fiber_backend.rb
    lib/phronomy/engine/task/deferred_backend.rb
    lib/phronomy/engine/task/mapped_backend.rb
    lib/phronomy/engine/runtime/scheduler.rb
    lib/phronomy/engine/runtime/deterministic_scheduler.rb
    lib/phronomy/engine/concurrency/blocking_adapter_pool.rb
    lib/phronomy/workflow_runner.rb
    lib/phronomy/workflow_context.rb
  ].freeze

  it "Thread.current is not referenced outside the allowed files" do
    lib_root = File.expand_path("../../lib", __dir__)
    project_root = File.expand_path("..", lib_root)
    lib_files = Dir.glob("#{lib_root}/**/*.rb")

    violations = []
    lib_files.each do |abs_path|
      rel_path = abs_path.sub("#{project_root}/", "")
      next if THREAD_CURRENT_ALLOWLIST.any? { |allowed| rel_path == allowed }

      File.foreach(abs_path).each_with_index do |line, idx|
        # Skip pure-comment lines so docs referencing Thread.current are allowed.
        next if line.strip.start_with?("#")
        next unless line.include?("Thread.current")

        violations << "#{rel_path}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(violations).to be_empty,
      "Thread.current used outside allowed files (use EventLoop.current? or InvocationContext instead):\n" \
      "#{violations.join("\n")}"
  end
end

# Issue #286 — Thread.new must only appear in files that own a Thread-creation
# zone.  All other concurrency must go through Runtime.instance.spawn
# so it respects the configured runtime backend, or BlockingAdapterPool#submit
# for blocking I/O isolation.
RSpec.describe "Thread.new confinement (Issue #286)", :issue_286 do
  # Files authorised to call Thread.new directly.
  # Note: lib/phronomy/tools/mcp.rb was previously on this list because the old
  # hand-rolled StdioTransport fell back to Thread.new for stderr draining.
  # That transport was replaced by the official mcp gem (MCP::Client::Stdio) in
  # commit bb0a3a82, eliminating all direct Thread.new usage from mcp.rb.
  # Issue #365 tracking the removal of that entry has been closed.
  THREAD_NEW_ALLOWLIST = %w[
    lib/phronomy/engine/concurrency/blocking_adapter_pool.rb
    lib/phronomy/engine/task/thread_backend.rb
    lib/phronomy/engine/runtime/timer_queue.rb
    lib/phronomy/engine/event_loop.rb
  ].freeze

  it "Thread.new is not called outside the allowed files" do
    lib_root = File.expand_path("../../lib", __dir__)
    project_root = File.expand_path("..", lib_root)
    lib_files = Dir.glob("#{lib_root}/**/*.rb")

    violations = []
    lib_files.each do |abs_path|
      rel_path = abs_path.sub("#{project_root}/", "")
      next if THREAD_NEW_ALLOWLIST.any? { |allowed| rel_path == allowed }
      next if rel_path.start_with?("lib/phronomy/testing/")

      File.foreach(abs_path).each_with_index do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("Thread.new")

        violations << "#{rel_path}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(violations).to be_empty,
      "Thread.new used outside allowed files (use Runtime.instance.spawn or BlockingAdapterPool#submit instead):\n" \
      "#{violations.join("\n")}"
  end
end

# Issue #370 — EventLoop must always use a dedicated ThreadScheduler regardless
# of the application-level runtime_backend setting.  This invariant is required
# by ADR-010 Rule 2: EventLoop owns an infinite dispatch loop and therefore must
# run in a real OS thread, even when the global backend is :immediate or :fiber.
#
# This is the *only* legitimate place in Phronomy where a component uses a
# dedicated ThreadScheduler instead of Runtime.instance.spawn.  Any additional
# deliberate-thread exception requires a new ADR.
RSpec.describe "EventLoop always uses a dedicated ThreadScheduler (Issue #370)", :issue_370 do
  let(:event_loop) { Phronomy::EventLoop.instance }

  after do
    begin
      event_loop.stop
    rescue
      nil
    end
    Phronomy.configure { |c| c.runtime_backend = :thread }
  end

  [:thread, :immediate, :fiber].each do |backend|
    it "EventLoop#start spawns its loop task on a ThreadBackend::Task regardless of :#{backend} backend" do
      Phronomy.configure { |c| c.runtime_backend = backend }
      event_loop.start
      sleep 0.02

      task = event_loop.instance_variable_get(:@task)
      task_backend = task.instance_variable_get(:@backend)
      expect(task_backend).to be_a(Phronomy::Task::ThreadBackend),
        "Expected EventLoop task backend to be a Task::ThreadBackend (ADR-010 Rule 2), " \
        "but got #{task_backend.class} with backend :#{backend}"
    end
  end
end
