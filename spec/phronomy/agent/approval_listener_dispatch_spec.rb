# frozen_string_literal: true

require "spec_helper"

RSpec.describe "approval listener execution boundary" do
  let(:coordinator) { Phronomy::Agent::ExecutionCoordinator.allocate }
  let(:logger) { double("logger", warn: nil) }

  before { Phronomy.configure { |config| config.logger = logger } }
  after { Phronomy.reset_configuration! }

  it "reports queue rejection without executing or raising from the listener" do
    Phronomy.configure do |config|
      config.offload_pool_size = 1
      config.offload_queue_size = 1
    end
    started = Queue.new
    release = Queue.new
    running = Phronomy::Blocking.call_async do
      started << true
      release.pop
    end
    Timeout.timeout(3) { started.pop }
    queued = Phronomy::Blocking.call_async { :queued }
    listener = double("listener")
    expect(listener).not_to receive(:call)

    expect { coordinator.send(:dispatch_approval_listener, listener, :request) }.not_to raise_error
    expect(logger).to have_received(:warn).with(/approval listener dispatch failed.*BackpressureError/).once
    release << true
    running.wait_result(timeout: 3)
    expect(queued.wait_result(timeout: 3)).to eq(:queued)
  ensure
    release << true if release
  end

  it "reports a listener failure after dispatch returns" do
    entered = Queue.new
    release = Queue.new
    reported = Queue.new
    allow(logger).to receive(:warn) { |message| reported << message }
    listener = lambda do |request|
      entered << request
      release.pop
      raise "listener failed"
    end

    coordinator.send(:dispatch_approval_listener, listener, :approval)
    expect(Timeout.timeout(3) { entered.pop }).to eq(:approval)
    expect(reported).to be_empty
    release << true
    expect(Timeout.timeout(3) { reported.pop }).to match(/approval listener dispatch failed.*listener failed/)
    expect(logger).to have_received(:warn).once
  ensure
    release << true if release
  end
end
