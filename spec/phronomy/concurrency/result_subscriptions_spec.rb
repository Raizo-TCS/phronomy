# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Concurrency::ResultSubscriptions do
  let(:token) { Phronomy::Concurrency::CancellationToken.new }
  let(:subscriptions) { described_class.new }

  it "delivers explicit cancellation and removes a registration closed before cancellation" do
    calls = []
    subscriptions.explicit_cancellation(token) { calls << :closed }
    subscriptions.close
    subscriptions.close
    active = described_class.new
    active.explicit_cancellation(token) { calls << :active }
    token.cancel!
    token.cancel!
    expect(calls).to eq([:active])
  end

  it "delivers an already cancelled token once even when the callback closes inline" do
    calls = []
    token.cancel!
    subscriptions.explicit_cancellation(token) do
      calls << :cancelled
      subscriptions.close
    end
    token.cancel!
    expect(calls).to eq([:cancelled])
  end

  it "does not promote an expired deadline to explicit cancellation" do
    expired = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    calls = []
    expect(Phronomy::Execution).not_to receive(:after)
    subscriptions.explicit_cancellation(expired) { calls << :cancelled }
    expect(expired).to be_cancelled
    expect(calls).to be_empty
    expired.cancel!
    expect(calls).to eq([:cancelled])
  end

  it "preserves the separate existing cancellation-state check" do
    expired = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
    calls = []
    subscriptions.cancellation(expired) { calls << :cancelled }
    expect(calls).to eq([:cancelled])
    subscriptions.close
    expired.cancel!
    expect(calls).to eq([:cancelled])
  end

  it "accepts an absent token without invoking the callback" do
    subscriptions.explicit_cancellation(nil) { raise "must not run" }
    expect { subscriptions.close }.not_to raise_error
  end

  it "keeps callback failure isolation in the token" do
    calls = []
    subscriptions.explicit_cancellation(token) { raise "first callback" }
    subscriptions.explicit_cancellation(token) { calls << :second }
    expect { token.cancel! }.not_to raise_error
    expect(calls).to eq([:second])
  end

  it "disposes a registration when close races the return from on_cancel" do
    registered = Queue.new
    release = Queue.new
    calls = []
    allow(token).to receive(:on_cancel).and_wrap_original do |original, &callback|
      original.call(&callback)
      registered << true
      release.pop
    end
    thread = Thread.new { subscriptions.explicit_cancellation(token) { calls << :cancelled } }
    Timeout.timeout(2) { registered.pop }
    subscriptions.close
    release << true
    expect(thread.join(2)).to equal(thread)
    thread.value
    token.cancel!
    expect(calls).to be_empty
  ensure
    release << true if release
    thread&.join(2)
  end

  it "preserves delivery of a callback already taken by a concurrent cancel" do
    delivering = Queue.new
    release = Queue.new
    calls = []
    token.on_cancel do
      delivering << true
      release.pop
    end
    subscriptions.explicit_cancellation(token) { calls << :cancelled }
    thread = Thread.new { token.cancel! }
    Timeout.timeout(2) { delivering.pop }
    subscriptions.close
    release << true
    expect(thread.join(2)).to equal(thread)
    thread.value
    expect(calls).to eq([:cancelled])
  ensure
    release << true if release
    thread&.join(2)
  end
end
