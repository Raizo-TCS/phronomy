# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::EventLoop, "queue observability" do
  class QueueObservabilitySession
    attr_reader :id

    def initialize(id:, event_loop:, started:, release:)
      @id = id
      @event_loop = event_loop
      @started = started
      @release = release
    end

    def start
      @started << true
      @release.pop
      @event_loop.post(
        Phronomy::Event.new(
          type: :finished,
          target_id: Phronomy::EventLoop::SYSTEM_CHANNEL_ID,
          payload: {fsm_session_id: id, result: :finished}
        )
      )
    end

    def handle(_event)
    end
  end

  let(:runtime) { Phronomy::Runtime.new }
  let(:event_loop) { runtime.event_loop }

  after do
    runtime.shutdown(timeout: 2)
  rescue
    nil
  end

  def block_dispatcher
    started = Queue.new
    release = Queue.new
    completion = Phronomy::Task.deferred(name: "event-loop-queue-observability")
    session = QueueObservabilitySession.new(
      id: "queue-observability-session",
      event_loop: event_loop,
      started: started,
      release: release
    )

    event_loop.register(session, completion: completion)
    started.pop
    [session, release, completion]
  end

  def queued_event(session, index)
    Phronomy::Event.new(
      type: :queue_observability_probe,
      target_id: session.id,
      payload: {index: index}
    )
  end

  it "tracks the current and maximum queue depth" do
    session, release, completion = block_dispatcher

    3.times do |index|
      expect(event_loop.post(queued_event(session, index))).to be(true)
    end

    expect(event_loop.queue_depth).to eq(3)
    expect(event_loop.max_queue_depth).to be >= 3

    release << true
    expect(completion.wait_result).to eq(:finished)
    expect(event_loop.queue_depth).to eq(0)
    expect(event_loop.max_queue_depth).to be >= 3
  end

  it "emits one rate-limited warning after the backlog threshold is reached" do
    stub_const("Phronomy::EventLoop::QUEUE_BACKLOG_WARNING_THRESHOLD", 2)
    stub_const("Phronomy::EventLoop::QUEUE_BACKLOG_WARNING_INTERVAL_SECONDS", 60.0)
    logger = double("logger")
    Phronomy.configuration.logger = logger
    session, release, completion = block_dispatcher

    expect(logger).to receive(:warn).once.with(
      include(
        "Queue backlog is high",
        "depth=2",
        "threshold=2",
        "event=:queue_observability_probe",
        "target_id=\"queue-observability-session\""
      )
    )

    3.times do |index|
      expect(event_loop.post(queued_event(session, index))).to be(true)
    end

    release << true
    expect(completion.wait_result).to eq(:finished)
  end

  it "does not fail event admission when backlog reporting itself fails" do
    stub_const("Phronomy::EventLoop::QUEUE_BACKLOG_WARNING_THRESHOLD", 2)
    logger = double("logger")
    allow(logger).to receive(:warn).and_raise("logger failed")
    Phronomy.configuration.logger = logger
    session, release, completion = block_dispatcher

    expect(event_loop.post(queued_event(session, 1))).to be(true)
    expect(event_loop.post(queued_event(session, 2))).to be(true)

    release << true
    expect(completion.wait_result).to eq(:finished)
  end
end
