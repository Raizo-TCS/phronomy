# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Phronomy::RetainedAttempts do
  let(:owner_mutex) { Mutex.new }
  let(:attempts) { described_class.new(mutex: owner_mutex) }
  let(:id) { Object.new.freeze }
  let(:observer) { Phronomy::TaskResult.deferred }
  let(:submitter) { Object.new }

  def facts(identity = nil)
    owner_mutex.synchronize { attempts.snapshot_locked(identity) }
  end

  def reserve(identity = id, waiting = observer)
    attempts.register(waiting)
    owner_mutex.synchronize { attempts.reserve_locked(identity, observer: waiting, kind: :read) }
  end

  def submit(identity = id, &work)
    attempts.submit(identity, submitter: submitter, missing_handle_message: "missing test handle", &work)
  end

  it "provides detached immutable facts without freezing domain payloads or exposing internal records" do
    reserve
    before = facts(id)
    payload = {value: "mutable"}
    owner_mutex.synchronize { attempts.record_worker_locked(id, payload, nil) }
    after = facts(id)

    expect(before).to be_frozen
    expect(after).to be_frozen
    expect(before[:result]).to be_nil
    expect(after[:result]).to equal(payload)
    expect(after.keys).not_to include(:completion, :observers, :task)
    expect { after[:started] = true }.to raise_error(FrozenError)
    payload[:value] = "still owned by the domain"
    expect(facts(id)[:result][:value]).to eq("still owned by the domain")
  end

  it "reserves one lane without executing work and fences joins and retirement by exact identity" do
    identity = "read"
    other_identity = (+"read").freeze
    reserve(identity)
    expect(Phronomy::Execution).not_to receive(:submit_with_rejection_evidence)

    owner_mutex.synchronize do
      expect { attempts.reserve_locked(other_identity, observer: observer) }.to raise_error(Phronomy::Error)
      expect(attempts.join_locked(other_identity, observer: observer)).to be(false)
      expect(attempts.retire_locked(other_identity)).to be_empty
      expect(attempts.active_snapshot_locked[:id]).to equal(identity)
    end
    expect(attempts.retire(identity)).to eq([observer])
    expect(owner_mutex.synchronize { attempts.active_snapshot_locked }).to be_nil
  end

  it "detaches a cancelled observer without retiring its lane or cancelling accepted work" do
    reserve
    task = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    work = nil
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |*, **, &block|
      work = block
      task
    end
    submit { :saved }
    attempts.watch(id) { |_event| }
    observer.cancel!

    expect(attempts.observers).to be_empty
    expect(owner_mutex.synchronize { attempts.take_observers_locked(id) }).to be_empty
    expect(facts(id)).to include(physical: false)
    expect(task.status).to eq(:pending)
    task.complete(work.call)
    task.mark_physical_complete!
    expect(facts(id)).to include(physical: true, result: :saved)
  end

  it "uses positive refusal evidence without inferring refusal from an exception" do
    failure = IOError.new("executor refused")
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |*, on_rejected:, **|
      on_rejected.call(failure)
      raise failure
    end
    expect { submit(nil) { raise "worker must not run" } }.to raise_error(failure)
    expect(facts).to include(rejection_confirmed: true, started: false,
      admission_unknown: false, physical: true, logical: true, error: failure)
  end

  it "retains unknown admission and its lane after a missing handle and a late hidden worker result" do
    reserve
    work = nil
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |*, **, &block|
      work = block
      nil
    end
    expect { submit { :late } }.to raise_error(Phronomy::Error, "missing test handle")
    work.call

    expect(facts(id)).to include(admission_unknown: true, started: true, physical: false, result: :late)
    expect(owner_mutex.synchronize { attempts.active_snapshot_locked[:id] }).to equal(id)
    expect(attempts.refresh(id)).to be(false)
  end

  it "does not classify a started worker as refused even when a refusal callback was invoked" do
    failure = IOError.new("submission response lost")
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |*, on_rejected:, **, &work|
      on_rejected.call(failure)
      work.call
      raise failure
    end
    expect { submit(nil) { :saved } }.to raise_error(failure)
    expect(facts).to include(started: true, rejection_confirmed: true,
      admission_unknown: true, physical: false, result: :saved)
  end

  it "binds inline completion callbacks outside the owner's mutex after the task is attached" do
    reserve
    task = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |*, **, &work|
      task.complete(work.call)
      task.mark_physical_complete!
      task
    end
    submit { :saved }
    events = []
    Timeout.timeout(2) { attempts.watch(id) { |event| events << [event, facts(id)] } }

    expect(events.map(&:first)).to eq(%i[physical logical])
    expect(events.last.last).to include(result: :saved, physical: true, logical: true)
  end

  it "retains the accepted lane and partial physical subscription when logical binding fails" do
    reserve
    task = Phronomy::Concurrency::PhysicalCompletionTask.deferred
    failure = IOError.new("logical subscription unavailable")
    allow(task).to receive(:on_complete).and_raise(failure)
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence).and_return(task)
    submit { :saved }
    events = []
    expect { attempts.watch(id) { |event| events << event } }.to raise_error(failure)
    task.mark_physical_complete!

    expect(facts(id)).to include(physical: true, physical_watch: true, watch_error: failure)
    expect(events).to eq([:physical])
    expect(owner_mutex.synchronize { attempts.active_snapshot_locked[:id] }).to equal(id)
  end

  it "retains a lane when failed delivery takes its observers" do
    reserve
    owner_mutex.synchronize do
      expect(attempts.take_observers_locked(id)).to eq([observer])
      expect(attempts.active_snapshot_locked[:id]).to equal(id)
    end
    next_observer = Phronomy::TaskResult.deferred
    attempts.register(next_observer)
    owner_mutex.synchronize do
      expect(attempts.join_locked(id, observer: next_observer)).to be(true)
      expect(attempts.retire_locked(id)).to eq([next_observer])
    end
  end

  it "keeps an old refresh isolated when the owner retires its lane and reserves a replacement" do
    reserve
    entered, resume = Queue.new, Queue.new
    task = Object.new
    task.define_singleton_method(:__snapshot) do
      entered << true
      resume.pop
      [:completed, :old_result, nil]
    end
    owner_mutex.synchronize { attempts.task_returned_locked(id, task) }
    refreshing = Thread.new { attempts.refresh(id) }
    Timeout.timeout(2) { entered.pop }
    replacement_id = Object.new.freeze
    attempts.retire(id)
    reserve(replacement_id, Phronomy::TaskResult.deferred)
    resume << true
    Timeout.timeout(2) { refreshing.join }

    expect(facts(replacement_id)).to include(physical: false, logical: false, result: nil)
    expect(facts(id)).to be_nil
  ensure
    resume << true if defined?(resume)
    refreshing&.join(2)
  end

  it "records the original diagnostic in the same critical section as the worker fact" do
    failure = IOError.new("save failed")
    diagnostic = nil
    core = described_class.new(mutex: owner_mutex, on_worker_recorded: lambda do |identity, _result, error|
      expect(owner_mutex).to be_owned
      diagnostic ||= error if identity.nil?
    end)
    allow(Phronomy::Execution).to receive(:submit_with_rejection_evidence) do |*, **, &work|
      work.call
    end
    expect { core.submit(nil, submitter: submitter, missing_handle_message: "missing") { raise failure } }.to raise_error(failure)
    owner_mutex.synchronize do
      expect(core.snapshot_locked(nil)[:error]).to equal(failure)
      expect(diagnostic).to equal(failure)
    end
  end
end
