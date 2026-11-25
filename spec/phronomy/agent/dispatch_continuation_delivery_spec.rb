# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::DispatchContinuationDelivery do
  let(:sink) { double("original session sink", fsm_session_id: "dispatch-session") }
  let(:delivery) { described_class.new(event_sink: sink) }

  it "resends the exact rejected progress message without retaining caller mutations" do
    original = {"tool_invocation_id" => ["original"]}
    seen = []
    allow(sink).to receive(:post) do |type, payload|
      seen << [type, payload]
      seen.length > 1
    end
    expect(delivery.fsm_session_id).to eq("dispatch-session")
    expect(delivery.post(:tool_failed, original)).to be(false)
    original.fetch("tool_invocation_id") << "changed"
    expect(delivery.finish_handoff?).to be(false)
    expect(delivery.retry_rejected!).to be(true)
    expect(seen.length).to eq(2)
    expect(seen.last).to eq(seen.first)
    expect(seen.last.last).to equal(seen.first.last)
    expect(seen.last.last).to eq("tool_invocation_id" => ["original"])
    expect(seen.last.last).to be_frozen
    expect(delivery.finish_handoff?).to be(true)
    expect(delivery.retry_rejected!).to be(true)
    expect(seen.length).to eq(2)
  end

  %i[
    llm_setup_failed llm_failed llm_completed tool_setup_failed tool_dispatch_prepared
    tool_failed tool_completed tool_cancelled tool_rejected tool_authorized tool_approval_required
  ].each do |type|
    it "retains #{type} until its exact positive rejection is repaired" do
      allow(sink).to receive(:post).with(type, nil).and_return(false, false, true)
      expect(delivery.post(type, nil)).to be(false)
      expect(delivery.retry_rejected!).to be(false)
      expect(delivery.finish_handoff?).to be(false)
      expect(delivery.retry_rejected!).to be(true)
      expect(delivery.finish_handoff?).to be(true)
      expect(sink).to have_received(:post).with(type, nil).exactly(3).times
    end
  end

  it "never resends a message whose admission reply raised after acceptance" do
    accepted = []
    allow(sink).to receive(:post) do |type, payload|
      accepted << [type, payload]
      raise IOError, "accepted message lost its receipt"
    end
    expect { delivery.post(:llm_failed, :failure) }.to raise_error(IOError, /lost its receipt/)
    expect(delivery.retry_rejected!).to be(false)
    expect(delivery.finish_handoff?).to be(false)
    expect(accepted).to eq([[:llm_failed, :failure]])
  end

  it "does not treat a missing boolean admission result as positive refusal" do
    allow(sink).to receive(:post).and_return(nil)
    expect(delivery.post(:llm_setup_failed, :failure)).to be_nil
    expect(delivery.retry_rejected!).to be(false)
    expect(delivery.finish_handoff?).to be(false)
    expect(sink).to have_received(:post).once
  end

  it "retains an unknown resend instead of replaying it again" do
    calls = 0
    allow(sink).to receive(:post) do |_type, _payload|
      calls += 1
      next false if calls == 1
      raise IOError, "retry receipt lost"
    end
    delivery.post(:tool_dispatch_prepared, nil)
    expect { delivery.retry_rejected! }.to raise_error(IOError, "retry receipt lost")
    expect(delivery.retry_rejected!).to be(false)
    expect(delivery.finish_handoff?).to be(false)
    expect(calls).to eq(2)
  end

  it "does not seal or duplicate delivery while a reserved post is in flight" do
    entered, release = Queue.new, Queue.new
    allow(sink).to receive(:post) do |_type, _payload|
      entered << true
      release.pop
      true
    end
    thread = Thread.new { delivery.post(:llm_completed, :result) }
    entered.pop
    expect(delivery.finish_handoff?).to be(false)
    expect(delivery.retry_rejected!).to be(false)
    release << true
    expect(thread.value).to be(true)
    expect(delivery.finish_handoff?).to be(true)
    expect(sink).to have_received(:post).once
  ensure
    release << true if thread&.alive?
    thread&.join
  end

  it "serializes retry attempts and keeps the handoff open through delegate callbacks" do
    entered, release = Queue.new, Queue.new
    calls = 0
    allow(sink).to receive(:post) do |_type, _payload|
      calls += 1
      next false if calls == 1
      expect(delivery.finish_handoff?).to be(false)
      entered << true
      release.pop
      true
    end
    delivery.post(:tool_failed, :failure)
    thread = Thread.new { delivery.retry_rejected! }
    entered.pop
    expect(delivery.retry_rejected!).to be(false)
    expect(delivery.finish_handoff?).to be(false)
    release << true
    expect(thread.value).to be(true)
    expect(delivery.finish_handoff?).to be(true)
    expect(calls).to eq(2)
  ensure
    release << true if thread&.alive?
    thread&.join
  end

  it "keeps distinct identical messages in flight until each admission returns" do
    entered = Queue.new
    releases = [Queue.new, Queue.new]
    lock = Mutex.new
    calls = 0
    allow(sink).to receive(:post) do |_type, _payload|
      index = lock.synchronize { calls += 1 } - 1
      entered << index
      releases.fetch(index).pop
      true
    end
    first = Thread.new { delivery.post(:tool_failed, {"same" => "message"}) }
    expect(entered.pop).to eq(0)
    second = Thread.new { delivery.post(:tool_failed, {"same" => "message"}) }
    expect(entered.pop).to eq(1)
    releases.first << true
    expect(first.value).to be(true)
    expect(delivery.finish_handoff?).to be(false)
    releases.last << true
    expect(second.value).to be(true)
    expect(delivery.finish_handoff?).to be(true)
  ensure
    releases&.each { |queue| queue << true }
    first&.join
    second&.join
  end

  it "forwards stream chunks without turning their observation into a handoff retry" do
    allow(sink).to receive(:post).with(:llm_stream_chunk, "token").and_return(false)
    expect(delivery.post(:llm_stream_chunk, "token")).to be(false)
    expect(delivery.finish_handoff?).to be(true)
    expect(delivery.retry_rejected!).to be(true)
    expect(sink).to have_received(:post).once
  end

  it "preserves normal asynchronous delivery after the handoff has sealed" do
    expect(delivery.finish_handoff?).to be(true)
    payload = {"result" => "later"}
    expect(sink).to receive(:post).with(:llm_completed, equal(payload)).and_return(false)
    expect(delivery.post(:llm_completed, payload)).to be(false)
    expect(delivery.retry_rejected!).to be(true)
    expect(delivery.finish_handoff?).to be(true)
  end
end
