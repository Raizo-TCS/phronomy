# frozen_string_literal: true

RSpec.describe "Cooperative scheduler fairness (Issue #269)" do
  let(:loop_instance) do
    el = Phronomy::EventLoop.new
    el.start
    el
  end

  after { loop_instance.stop(timeout: 2) }

  describe "EventLoop lag metrics" do
    it "records last_lag_seconds after dispatching an event" do
      Thread::Queue.new
      wf = Class.new do
        include Phronomy::WorkflowContext

        field :done, default: -> { false }
      end
      app = Phronomy::Workflow.define(wf) do
        initial :step
        state :step, action: ->(state) { state.merge(done: true) }
        transition from: :step, to: :__finish__
      end

      # invoke via the loop to trigger at least one dispatch
      loop_instance # ensure started
      result = app.invoke({}, config: {thread_id: "lag-test-#{SecureRandom.hex(4)}"})
      expect(result.done).to be(true)

      # Lag may be very small (nanoseconds) in a test but must be >= 0
      expect(Phronomy::EventLoop.instance.last_lag_seconds).to be >= 0
      expect(Phronomy::EventLoop.instance.max_lag_seconds).to be >= 0
      expect(Phronomy::EventLoop.instance.average_lag_seconds).to be >= 0
    end

    it "max_lag_seconds is >= last_lag_seconds" do
      expect(Phronomy::EventLoop.instance.max_lag_seconds).to be >=
        Phronomy::EventLoop.instance.last_lag_seconds
    end
  end

  describe "Phronomy::Configuration fairness thresholds" do
    it "defaults starvation threshold to nil (disabled)" do
      config = Phronomy::Configuration.new
      expect(config.event_loop_starvation_threshold_seconds).to be_nil
    end

    it "defaults dispatch threshold to nil (disabled)" do
      config = Phronomy::Configuration.new
      expect(config.event_loop_dispatch_threshold_seconds).to be_nil
    end

    it "allows thresholds to be set" do
      config = Phronomy::Configuration.new
      config.event_loop_starvation_threshold_seconds = 0.5
      config.event_loop_dispatch_threshold_seconds = 0.1
      expect(config.event_loop_starvation_threshold_seconds).to eq(0.5)
      expect(config.event_loop_dispatch_threshold_seconds).to eq(0.1)
    end
  end

  describe "starvation warning" do
    it "emits a logger warning when lag exceeds starvation threshold" do
      logger = instance_double("Logger")
      allow(logger).to receive(:warn)

      Phronomy.configure do |c|
        c.event_loop = true
        c.event_loop_starvation_threshold_seconds = 0 # fire on every event
        c.logger = logger
      end
      Phronomy::EventLoop.instance # ensure started

      expect(logger).to receive(:warn).at_least(:once)

      # Trigger at least one event dispatch through the singleton
      wf = Class.new do
        include Phronomy::WorkflowContext

        field :done, default: -> { false }
      end
      app = Phronomy::Workflow.define(wf) do
        initial :step
        state :step, action: ->(state) { state.merge(done: true) }
        transition from: :step, to: :__finish__
      end
      app.invoke({}, config: {thread_id: "starv-test-#{SecureRandom.hex(4)}"})
    ensure
      Phronomy::EventLoop.reset!
      Phronomy.configure do |c|
        c.event_loop = false
        c.event_loop_starvation_threshold_seconds = nil
        c.logger = nil
      end
    end
  end
end
