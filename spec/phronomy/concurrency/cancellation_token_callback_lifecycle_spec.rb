# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::CancellationToken, "callback lifecycle" do
  it "releases registered callbacks before delivering explicit cancellation" do
    token = described_class.new
    calls = []

    token.on_cancel { calls << :called }
    token.cancel!

    expect(calls).to eq([:called])
    expect(token.instance_variable_get(:@cancel_callbacks)).to be_empty
  end

  it "allows framework code to unregister a callback that is no longer needed" do
    token = described_class.new
    calls = []
    callback = -> { calls << :called }

    token.on_cancel(&callback)
    token.send(:unregister_cancel_callback, callback)
    token.cancel!

    expect(calls).to be_empty
  end

  it "continues cancellation fan-out when one callback raises" do
    token = described_class.new
    calls = []

    token.on_cancel do
      calls << :first
      raise "boom"
    end
    token.on_cancel { calls << :second }
    token.on_cancel { calls << :third }

    expect { token.cancel! }.not_to raise_error
    expect(calls).to eq(%i[first second third])
  end

  it "isolates a callback registered after explicit cancellation" do
    token = described_class.new.cancel!

    expect {
      token.on_cancel { raise "late boom" }
    }.not_to raise_error
  end

  context "when reporting a callback failure also fails", :notification_reporting do
    before do
      logger = instance_double(Logger, error: nil, warn: nil)
      allow(logger).to receive(:error).and_raise(IOError, "logger unavailable")
      Phronomy.configuration.logger = logger
    end

    it "delivers every remaining notification exactly once" do
      token = described_class.new
      calls = []
      token.on_cancel do
        calls << :first
        raise ArgumentError, "observer failed"
      end
      token.on_cancel { calls << :second }
      token.on_cancel { calls << :third }

      expect { token.cancel! }.not_to raise_error
      expect(token).to be_cancelled
      expect(calls).to eq(%i[first second third])
      token.cancel!
      expect(calls).to eq(%i[first second third])
    end

    it "isolates a late observer without changing the cancelled token" do
      token = described_class.new.cancel!

      expect {
        token.on_cancel { raise ArgumentError, "late observer failed" }
      }.not_to raise_error
      expect(token).to be_cancelled
    end

    it "cancels queued public Blocking work before it can execute" do
      Phronomy.configuration.offload_pool_size = 1
      started = Queue.new
      release = Queue.new
      first = Phronomy::Blocking.call_async do
        started << true
        release.pop
      end
      expect(started.pop(timeout: 2)).to be(true)

      token = described_class.new
      token.on_cancel { raise ArgumentError, "application observer failed" }
      effects = []
      queued = Phronomy::Blocking.call_async(cancellation_token: token) { effects << :executed }

      expect { token.cancel! }.not_to raise_error
      expect(queued.status).to eq(:cancelled)
      expect { queued.wait_result(timeout: 2) }.to raise_error(Phronomy::CancellationError)
      release << true
      first.wait_result(timeout: 2)
      expect(Phronomy::Blocking.call_async { :after_cancelled_work }.wait_result(timeout: 2)).to eq(:after_cancelled_work)
      expect(effects).to be_empty
    ensure
      release << true if release
    end
  end
end
