# frozen_string_literal: true

require "spec_helper"

RSpec.describe "LLM SDK initialization isolation" do
  [:cancel, :deadline].each do |control|
    it "keeps EventLoop responsive during initialization and prevents HTTP after #{control}" do
      started, release, loop_progress, worker_done = Queue.new, Queue.new, Queue.new, Queue.new
      chat = double(:chat, after_message: nil)
      expect(chat).not_to receive(:complete)
      expect(chat).not_to receive(:ask)
      allow(RubyLLM).to receive(:chat) do
        started << Thread.current
        release.pop
        chat
      end
      agent_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "initialization-#{control}", version: 1
        model "independent-model"
      end
      token = (control == :deadline) ? Phronomy::Concurrency::CancellationToken.timeout_after(0.5) : Phronomy::Concurrency::CancellationToken.new
      options = {cancellation_token: token}
      # Observe physical backend return separately from logical task settlement.
      adapter = Phronomy.configuration.llm_adapter
      allow(adapter).to receive(:complete).and_wrap_original do |method, *args, **kwargs|
        method.call(*args, **kwargs)
      ensure
        worker_done << true
      end
      task = agent_class.new.invoke_async("hello", config: options)
      worker = started.pop(timeout: 3)
      expect(worker).not_to be_nil
      Phronomy::Execution.after(0) { loop_progress << Phronomy::Runtime.instance.event_loop_current? }
      expect(loop_progress.pop(timeout: 2)).to be(true)
      token.cancel! if control == :cancel
      expect { task.wait_result(timeout: 3) }.to raise_error { |error| expect(error).to be_a(Phronomy::CancellationError).or be_a(Phronomy::TimeoutError) }
      release << true
      expect(worker_done.pop(timeout: 3)).to be(true)
    ensure
      release&.push(true)
    end
  end
end
