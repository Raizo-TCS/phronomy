# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Phronomy::Agent::PhysicalAttempt do
  let(:owner_mutex) { Mutex.new }
  let(:attempt) { described_class.new(mutex: owner_mutex) }

  def snapshot(target = attempt)
    owner_mutex.synchronize { target.snapshot_locked }
  end

  def physical_task
    Phronomy::Concurrency::PhysicalCompletionTask.deferred(name: "physical-attempt-contract")
  end

  it "publishes inline completions before notifying an owner that takes the same mutex" do
    task = physical_task
    task.complete(:saved)
    task.mark_physical_complete!
    notifications = []

    attempt.watch(task) do |event|
      notifications << [event, owner_mutex.owned?, snapshot]
    end

    expect(notifications.map(&:first)).to eq(%i[physical logical])
    expect(notifications.map { |entry| entry[1] }).to eq([false, false])
    expect(notifications.first.last).to include(physical: true, logical: false)
    expect(notifications.last.last).to include(physical: true, logical: true, result: :saved, error: nil)
    expect(snapshot).to include(physical_watch: true)
  end

  it "retains late worker success after logical cancellation until physical completion" do
    task = physical_task
    notifications = []
    attempt.watch(task) { |event| notifications << [event, snapshot] }
    task.cancel!

    expect(snapshot).to include(logical: true, physical: false, result: nil)
    expect(snapshot.fetch(:error)).to be_a(Phronomy::CancellationError)
    owner_mutex.synchronize { attempt.record_worker_locked(:committed, nil) }
    task.mark_physical_complete!
    expect(attempt.refresh).to be(true)

    expect(snapshot).to include(logical: true, physical: true, result: :committed, error: nil)
    expect(notifications.map(&:first)).to eq(%i[logical physical])
    expect(task.__snapshot.first).to eq(:cancelled)
  end

  it "preserves an explicitly recorded nil success instead of adopting task cancellation" do
    task = physical_task
    owner_mutex.synchronize { attempt.record_worker_locked(nil, nil) }
    attempt.watch(task) { |_event| }
    task.cancel!
    task.mark_physical_complete!
    attempt.refresh

    expect(snapshot).to include(logical: true, physical: true, result: nil, error: nil)
  end

  it "keeps the worker's fatal exception distinct from a later logical task error" do
    task = physical_task
    fatal = Exception.new("worker terminated outside StandardError")
    owner_mutex.synchronize { attempt.record_worker_locked(nil, fatal) }
    attempt.watch(task) { |_event| }
    task.fail(IOError.new("logical observer failed"))
    task.mark_physical_complete!
    attempt.refresh

    expect(snapshot.fetch(:error)).to equal(fatal)
    expect(snapshot).to include(logical: true, physical: true, result: nil)
  end

  it "preserves a worker result published while a logical snapshot is being read" do
    task = physical_task
    task.cancel!
    entered = Queue.new
    release = Queue.new
    owner_mutex.synchronize { attempt.attach_locked(task) }
    allow(task).to receive(:__snapshot).and_wrap_original do |original|
      observed = original.call
      entered << true
      release.pop
      observed
    end
    refreshing = Thread.new { attempt.refresh }
    Timeout.timeout(2) { entered.pop }
    owner_mutex.synchronize { attempt.record_worker_locked(:committed_during_poll, nil) }
    release << true

    expect(Timeout.timeout(2) { refreshing.value }).to be(true)
    expect(snapshot).to include(logical: true, physical: false, result: :committed_during_poll, error: nil)
  ensure
    release << true if release
    refreshing&.kill if refreshing&.alive?
    refreshing&.join
  end

  it "uses an ordinary TaskResult's logical completion as its physical boundary" do
    task = Phronomy::TaskResult.deferred
    notifications = []
    attempt.watch(task) { |event| notifications << event }
    task.complete(:ordinary)

    expect(snapshot).to include(logical: true, physical: true, result: :ordinary, physical_watch: false)
    expect(notifications).to eq([:logical])
  end

  it "does not infer physical completion from a logical snapshot when only a physical callback exists" do
    task = Phronomy::TaskResult.deferred
    physical_callbacks = []
    task.define_singleton_method(:on_physical_complete) { |&callback| physical_callbacks << callback }
    attempt.watch(task) { |_event| }
    task.complete(:logical_only)
    attempt.refresh

    expect(snapshot).to include(logical: true, physical: false, result: :logical_only)
    physical_callbacks.fetch(0).call
    expect(snapshot.fetch(:physical)).to be(true)
  end

  %i[on_physical_complete on_complete].each do |registration|
    it "keeps the handle after #{registration} fails before installation and refreshes later facts" do
      task = physical_task
      failure = IOError.new("subscription unavailable")
      allow(task).to receive(registration).and_raise(failure)

      expect { attempt.watch(task) { |_event| } }.to raise_error { |error| expect(error).to equal(failure) }
      expect(owner_mutex.synchronize { attempt.task }).to equal(task)
      expect(snapshot).to include(logical: false, physical: false, watch_error: failure,
        physical_watch: registration == :on_complete)
      task.complete(:late_result)
      task.mark_physical_complete!
      expect(attempt.refresh).to be(true)

      expect(snapshot).to include(logical: true, physical: true, result: :late_result, watch_error: failure)
    end

    it "retains published facts when #{registration} installs the callback and then raises" do
      task = physical_task
      failure = IOError.new("subscription reply lost")
      notifications = []
      allow(task).to receive(registration).and_wrap_original do |original, &callback|
        original.call(&callback)
        raise failure
      end

      expect { attempt.watch(task) { |event| notifications << [event, snapshot] } }
        .to raise_error { |error| expect(error).to equal(failure) }
      task.complete(:late_result)
      task.mark_physical_complete!
      attempt.refresh

      expect(snapshot).to include(logical: true, physical: true, result: :late_result, watch_error: failure,
        physical_watch: registration == :on_complete)
      expected_events = (registration == :on_complete) ? %i[logical physical] : [:physical]
      expect(notifications.map(&:first)).to eq(expected_events)
    end
  end

  it "reads task snapshots and physical evidence outside the owner mutex" do
    task = physical_task
    owner_mutex.synchronize { attempt.attach_locked(task) }
    allow(task).to receive(:__snapshot).and_wrap_original do |original|
      expect(owner_mutex.owned?).to be(false)
      owner_mutex.synchronize { true }
      original.call
    end
    allow(task).to receive(:physical_complete?).and_wrap_original do |original|
      expect(owner_mutex.owned?).to be(false)
      owner_mutex.synchronize { true }
      original.call
    end

    expect(attempt.refresh).to be(true)
    expect(snapshot).to include(logical: false, physical: false)
  end

  it "never retracts physical completion when a later poll has no completion evidence" do
    task = physical_task
    attempt.watch(task) { |_event| }
    task.mark_physical_complete!
    allow(task).to receive(:physical_complete?).and_return(false)
    attempt.refresh

    expect(snapshot).to include(physical: true, logical: false)
  end

  it "does not publish a finished old attempt into a distinct replacement attempt" do
    old_task = physical_task
    replacement = described_class.new(mutex: owner_mutex)
    old_notifications = []
    replacement_notifications = []
    attempt.watch(old_task) { |event| old_notifications << event }
    replacement.watch(physical_task) { |event| replacement_notifications << event }

    old_task.complete(:old_result)
    old_task.mark_physical_complete!

    expect(snapshot).to include(physical: true, logical: true, result: :old_result)
    expect(snapshot(replacement)).to include(physical: false, logical: false, result: nil, error: nil)
    expect(old_notifications).to eq(%i[logical physical])
    expect(replacement_notifications).to be_empty
  end

  it "keeps recorded facts when owner notification raises" do
    task = physical_task
    attempted_notifications = []
    attempt.watch(task) do |event|
      attempted_notifications << event
      raise IOError, "owner mailbox unavailable"
    end
    task.complete(:retained)
    task.mark_physical_complete!

    expect(attempted_notifications).to eq(%i[logical physical])
    expect(snapshot).to include(logical: true, physical: true, result: :retained, error: nil)
  end

  it "keeps a frozen observation detached from subsequent recorded facts" do
    before = snapshot
    owner_mutex.synchronize { attempt.record_worker_locked(:recorded, nil) }

    expect(before).to be_frozen
    expect(before).to include(result: nil, error: nil)
    expect(snapshot).to include(result: :recorded, error: nil)
  end

  it "reports that refresh is unavailable until a task handle exists" do
    expect(attempt.refresh).to be(false)
    expect(owner_mutex.synchronize { attempt.task }).to be_nil
    expect(snapshot).to include(logical: false, physical: false)
  end

  [false, true].each do |physical|
    it "records the owner's physical=#{physical} conclusion on submission failure without classifying the exception" do
      failure = IOError.new("submission response unavailable")
      owner_mutex.synchronize { attempt.submission_failed_locked(failure, physical: physical) }

      expect(owner_mutex.synchronize { attempt.task }).to be_nil
      expect(snapshot).to include(logical: true, physical: physical, error: failure)
      expect(attempt.refresh).to be(false)
    end
  end

  it "clears heavy payloads after completion while retaining observed completion facts" do
    task = physical_task
    attempt.watch(task) { |_event| }
    task.complete(:original)
    task.mark_physical_complete!
    owner_mutex.synchronize { attempt.clear_locked }

    expect(owner_mutex.synchronize { attempt.task }).to be_nil
    expect(snapshot).to include(result: nil, error: nil, watch_error: nil,
      physical: true, logical: true)
    expect(attempt.refresh).to be(false)
  end
end
