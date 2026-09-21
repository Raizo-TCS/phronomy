# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Engine execution receiver lifecycle (ADR-042; F0/F3/F4, no X0)" do
  let(:runtime) { Phronomy::Runtime.new }
  let(:event_loop) { runtime.event_loop }
  let(:receiver_class) do
    Class.new(Phronomy::ExecutionReceiver) do
      attr_reader :entered, :release, :stopped
      attr_accessor :fail_shutdown

      def initialize(event_loop:)
        super
        @entered, @release, @stopped = Queue.new, Queue.new, Queue.new
        @held = false
      end

      def post(message, admission: false, completion: nil)
        post_message(message, admission: admission, completion: completion)
      end

      def deliver(message)
        assert_event_loop_thread!
        case message
        when :barrier
          @entered << :barrier
          @release.pop
        when :admit
          admit { @held = true }
          @entered << :admitted
        when :finish
          synchronize { @held = false }
        when :explode
          raise IOError, "dispatcher failed"
        end
      end

      def idle?
        !@held
      end

      def shutdown(error:)
        @stopped << [error, @event_loop.current?, @event_loop.thread_alive?]
        raise IOError, "receiver cleanup failed" if fail_shutdown
        synchronize { @held = false }
      end
    end
  end
  let(:receiver) { receiver_class.for(event_loop) }

  def take(queue)
    Timeout.timeout(3) { queue.pop }
  end

  def deadline
    Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
  end

  after { runtime.shutdown(timeout: 1) }

  it "retains one receiver per key and closes registration before idleness" do
    instances = 8.times.map { Thread.new { receiver_class.for(event_loop) } }.map(&:value)
    expect(instances.uniq).to eq([receiver])
    event_loop.begin_draining
    expect(receiver_class.for(event_loop)).to be(receiver)
    expect { Class.new(receiver_class).for(event_loop) }
      .to raise_error(Phronomy::RuntimeShutdownError)
    expect(event_loop).to be_idle
  end

  it "does not create an EventLoop for a lookup on an unused Runtime" do
    expect(receiver_class.existing_for(runtime)).to be_nil
    expect(runtime.__event_loop_if_initialized).to be_nil
  end

  it "rejects unregistered and foreign-loop receivers" do
    detached = receiver_class.new(event_loop: event_loop)
    expect(detached.post(:admit, admission: true)).to be(false)
    foreign_runtime = Phronomy::Runtime.new
    foreign = receiver_class.for(foreign_runtime.event_loop)
    expect { event_loop.__register_execution_receiver(key: receiver_class, receiver: foreign) }
      .to raise_error(ArgumentError, /this EventLoop/)
  ensure
    foreign_runtime&.shutdown(timeout: 1)
  end

  it "counts queued admissions, drains accepted work, and rejects late admissions" do
    expect(receiver.post(:barrier)).to be(true)
    expect(take(receiver.entered)).to eq(:barrier)
    expect(receiver.post(:admit, admission: true)).to be(true)
    event_loop.begin_draining
    expect(event_loop).not_to be_idle
    expect(receiver.post(:admit, admission: true)).to be(false)

    receiver.release << true
    expect(take(receiver.entered)).to eq(:admitted)
    expect(event_loop).not_to be_idle
    expect(receiver.post(:finish)).to be(true)
    expect(event_loop.wait_until_idle(deadline)).to be(true)
    expect(runtime.shutdown(timeout: 1)).to be_cleanup_complete
    expect(receiver.post(:finish)).to be(false)
    expect(take(receiver.stopped)).to eq([nil, false, false])
  ensure
    receiver.release << true
  end

  it "does not let a continuation acquire a new admission while draining" do
    receiver
    event_loop.begin_draining
    task = Phronomy::TaskResult.deferred(name: "illegal-admission")
    event_loop.instance_variable_get(:@thread).report_on_exception = false
    expect(receiver.post(:admit, completion: task)).to be(true)
    expect { task.wait_result(timeout: 3) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(runtime.shutdown(timeout: 1).runtime_outcome).to eq(:failed)
  end

  it "fails both the dispatching and queued requests if the loop fails" do
    first = Phronomy::TaskResult.deferred(name: "dispatching")
    second = Phronomy::TaskResult.deferred(name: "queued")
    event_loop.instance_variable_get(:@thread).report_on_exception = false
    receiver.post(:barrier)
    take(receiver.entered)
    receiver.post(:explode, completion: first)
    receiver.post(:admit, admission: true, completion: second)
    receiver.release << true
    [first, second].each do |task|
      expect { task.wait_result(timeout: 3) }.to raise_error(IOError, "dispatcher failed")
    end
    failure, current, alive = take(receiver.stopped)
    expect(failure).to be_a(IOError)
    expect([current, alive]).to eq([true, true])
    expect(runtime.shutdown(timeout: 1).runtime_outcome).to eq(:failed)
    expect(receiver.post(:finish)).to be(false)
  ensure
    receiver.release << true
  end

  it "retains incomplete cleanup while still visiting later receivers" do
    receiver.fail_shutdown = true
    later = Class.new(receiver_class).for(event_loop)
    result = runtime.shutdown(timeout: 1)
    expect(result).not_to be_cleanup_complete
    expect(result.runtime_outcome).to eq(:failed)
    expect(result.error.message).to eq("receiver cleanup failed")
    expect(take(later.stopped)).to eq([nil, false, false])
  end

  it "does not grant a caller thread mutation authority" do
    registry = Phronomy::Agent::ExecutionRegistry.for(event_loop)
    expect { registry.admit_agent_execution("agent", owner_token: Object.new) }
      .to raise_error(Phronomy::Error, /only be mutated on EventLoop/)
    workflow = Phronomy::WorkflowExecutionRegistry.for(event_loop)
    expect { workflow.admit_workflow("workflow", owner_token: Object.new) }
      .to raise_error(Phronomy::Error, /only be mutated on EventLoop/)
    expect(event_loop).to be_idle
  end
end
