# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Execution retirement completion custody" do
  let(:runtime) { Phronomy::Runtime.new }
  let(:event_loop) { runtime.event_loop }
  let(:receiver_class) do
    Class.new(Phronomy::ExecutionReceiver) do
      attr_accessor :mode
      attr_reader :attempts, :adopted, :legacy_notifications, :shutdown_error

      def initialize(channel:)
        super
        @mode = :accept
        @attempts = []
        @legacy_notifications = []
      end

      def post(message, completion: nil)
        post_message(message, completion: completion)
      end

      def deliver(message)
        assert_event_loop_thread!
        message.call
      end

      def idle? = @adopted.nil?

      def adopt_retirement(retirement)
        assert_event_loop_thread!
        @attempts << retirement
        case mode
        when :accept
          synchronize { @adopted = retirement }
          retirement.acceptance
        when :boolean then true
        when :refuse then nil
        when :foreign
          Phronomy::ExecutionRetirement.new(
            fsm_session_id: retirement.fsm_session_id,
            reason: retirement.reason, error: retirement.error
          ).acceptance
        when :raise then raise IOError, "custody adoption failed"
        when :legacy then super
        end
      end

      def session_retired(fsm_session_id, reason:)
        @legacy_notifications << [fsm_session_id, reason]
        true
      end

      def release
        assert_event_loop_thread!
        synchronize { @adopted = nil }
      end

      def shutdown(error:)
        @shutdown_error = error
      end
    end
  end
  let(:receiver) { receiver_class.for(event_loop) }

  def on_owner(&operation)
    task = Phronomy::TaskResult.deferred
    expect(receiver.post(-> { task.complete(operation.call) })).to be(true)
    task.wait_result(timeout: 2)
  end

  def register_source(id = "retiring-session")
    started = Queue.new
    session = Struct.new(:id, :started) do
      def start = started << true
    end.new(id, started)
    source = Phronomy::TaskResult.deferred
    event_loop.register(session, completion: source, receiver: receiver)
    Timeout.timeout(2) { started.pop }
    [source, id]
  end

  def retire(id, error = IOError.new("unknown persistence outcome"))
    expect(event_loop.post(Phronomy::Event.new(
      type: :recovery_required, target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
      payload: {fsm_session_id: id, error: error}
    ))).to be(true)
    on_owner { true }
  end

  after do
    if %i[running draining].include?(event_loop.state)
      receiver.mode = :accept
      ids = on_owner { event_loop.instance_variable_get(:@unaccepted_retirements).keys }
      ids.each { |id| retire(id) }
      on_owner { receiver.release }
    end
    runtime.shutdown(timeout: 0.1, cancel_grace: 0.1)
    thread = event_loop.instance_variable_get(:@thread)
    Timeout.timeout(2) { Thread.pass while thread&.alive? }
    expect(event_loop).not_to be_thread_alive
  end

  it "detaches and completes the exact source only after typed custody acceptance" do
    source, id = register_source
    observations = Queue.new
    source.on_complete do |value, error|
      observations << [value, error, receiver.adopted,
        event_loop.instance_variable_get(:@waiting).key?(id)]
    end
    original_error = IOError.new("readback unavailable")
    retire(id, original_error)

    value, error, adopted, still_waiting = Timeout.timeout(2) { observations.pop }
    expect(value).to be_a(Phronomy::ExecutionRetirement)
    expect(value).to be_frozen
    expect(value.fsm_session_id).to eq(id)
    expect(value.reason).to eq(:recovery_required)
    expect(value.error).to equal(original_error)
    expect(value).to equal(adopted)
    expect(error).to be_nil
    expect(still_waiting).to be(false)
    expect(event_loop.admitted_fsm_session?(id)).to be(false)
    expect(event_loop).not_to be_idle
    expect(receiver.legacy_notifications).to be_empty

    retire(id)
    expect(receiver.attempts).to eq([value])
    expect(source.wait_result(timeout: 2)).to equal(value)
  end

  %i[refuse boolean foreign raise].each do |mode|
    it "retains custody on #{mode} and accepts only the same envelope on a later attempt" do
      receiver.mode = mode
      source, id = register_source
      retire(id)
      first = receiver.attempts.fetch(0)

      expect(source.status).to eq(:pending)
      expect(event_loop.admitted_fsm_session?(id)).to be(false)
      expect(event_loop).not_to be_idle
      expect(event_loop.__receiver_cleanup_complete?).to be(false)
      pending = on_owner { event_loop.instance_variable_get(:@unaccepted_retirements).fetch(id) }
      expect(pending.fetch(:retirement)).to equal(first)
      expect(pending.fetch(:error)).to be_a((mode == :raise) ? IOError : Phronomy::Error)

      # A delayed ordinary terminal cannot bypass the custody decision.
      event_loop.post(Phronomy::Event.new(type: :finished,
        target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
        payload: {fsm_session_id: id, result: :incorrectly_finished}))
      on_owner { true }
      expect(source.status).to eq(:pending)

      receiver.mode = :accept
      retire(id)
      expect(source.wait_result(timeout: 2)).to equal(first)
      expect(receiver.attempts).to eq([first, first])
      expect(event_loop.__receiver_cleanup_complete?).to be(true)
    end
  end

  it "keeps the legacy retirement callback distinct from custody acceptance" do
    receiver.mode = :legacy
    source, id = register_source
    retire(id)
    expect(receiver.legacy_notifications).to eq([[id, :recovery_required]])
    expect(source.status).to eq(:pending)
    expect(receiver.adopted).to be_nil
    expect(event_loop.__receiver_cleanup_complete?).to be(true)
  end

  it "rejects session identity reuse before dispatch and while custody is refused" do
    receiver.mode = :refuse
    source, id = register_source
    entered = Queue.new
    release = Queue.new
    receiver.post(-> {
      entered << true
      release.pop
    })
    Timeout.timeout(2) { entered.pop }
    event_loop.post(Phronomy::Event.new(type: :recovery_required,
      target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
      payload: {fsm_session_id: id, error: IOError.new("unknown")}))
    duplicate = Struct.new(:id).new(id)
    expect(event_loop.admitted_fsm_session?(id)).to be(false)
    expect { event_loop.register(duplicate, completion: Phronomy::TaskResult.deferred, receiver: receiver) }
      .to raise_error(Phronomy::Error, /already registered/)
    release << true
    on_owner { true }
    expect { event_loop.register(duplicate, completion: Phronomy::TaskResult.deferred, receiver: receiver) }
      .to raise_error(Phronomy::Error, /already registered/)
    expect(on_owner { event_loop.instance_variable_get(:@waiting).fetch(id) }).to equal(source)
  ensure
    release << true
  end

  it "leaves ordinary terminal completion unchanged" do
    source, id = register_source
    event_loop.post(Phronomy::Event.new(type: :finished,
      target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
      payload: {fsm_session_id: id, result: :completed}))
    expect(source.wait_result(timeout: 2)).to eq(:completed)
    expect(receiver.attempts).to be_empty
    expect(event_loop).to be_idle
  end

  it "stops cooperatively after the shutdown deadline while preserving refused custody" do
    receiver.mode = :refuse
    source, id = register_source
    retire(id)
    thread = event_loop.instance_variable_get(:@thread)

    result = runtime.shutdown(timeout: 0.02, cancel_grace: 0.02)
    thread.join(2)
    expect(result).not_to be_cleanup_complete
    expect(result.event_loop_status).to eq(:cancel_timeout)
    expect(event_loop).not_to be_thread_alive
    expect(event_loop.__receiver_cleanup_complete?).to be(false)
    expect(source.status).to eq(:pending)
    expect(event_loop.instance_variable_get(:@waiting).fetch(id)).to equal(source)
    expect(event_loop.instance_variable_get(:@unaccepted_retirements).fetch(id).fetch(:retirement))
      .to equal(receiver.attempts.first)
    expect(receiver.shutdown_error).to be_a(Phronomy::RuntimeShutdownError)
    expect(runtime.shutdown(timeout: 1)).to equal(result)
  end

  it "does not fail a refused source through unrelated dispatcher failure cleanup" do
    receiver.mode = :refuse
    source, id = register_source
    retire(id)
    thread = event_loop.instance_variable_get(:@thread)
    thread.report_on_exception = false
    receiver.post(-> { raise IOError, "unrelated dispatcher failure" })
    expect { thread.join(2) }.to raise_error(IOError, "unrelated dispatcher failure")
    expect(event_loop).not_to be_thread_alive
    expect(source.status).to eq(:pending)
    expect(event_loop.instance_variable_get(:@waiting).fetch(id)).to equal(source)
    expect(event_loop.__receiver_cleanup_complete?).to be(false)
    expect(runtime.shutdown(timeout: 0.1)).not_to be_cleanup_complete
  end

  it "does not interrupt an active callback or execute queued work after abort" do
    entered = Queue.new
    release = Queue.new
    later = Phronomy::TaskResult.deferred
    called = false
    receiver.post(-> {
      entered << true
      release.pop
    })
    Timeout.timeout(2) { entered.pop }
    receiver.post(-> { called = true }, completion: later)
    thread = event_loop.instance_variable_get(:@thread)

    result = runtime.shutdown(timeout: 0.02, cancel_grace: 0.02)
    expect(result).not_to be_cleanup_complete
    expect(result.event_loop_status).to eq(:cancel_timeout)
    expect(thread).to be_alive
    release << true
    thread.join(2)
    expect(thread).not_to be_alive
    expect(called).to be(false)
    expect { later.wait_result(timeout: 2) }.to raise_error(Phronomy::RuntimeShutdownError)
    expect(runtime.shutdown(timeout: 1)).to equal(result)
  ensure
    release << true
  end
end
