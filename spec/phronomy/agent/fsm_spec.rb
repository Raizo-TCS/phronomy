# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::FSM do
  # Minimal fake EventLoop that captures posted events synchronously.
  class FakeEventLoop
    attr_reader :events

    def initialize
      @events = []
    end

    def post(event)
      @events << event
    end

    def register(fsm)
      cq = Thread::Queue.new
      fsm.start
      cq
    end
  end

  def with_fake_loop
    fake = FakeEventLoop.new
    allow(Phronomy::EventLoop).to receive(:instance).and_return(fake)
    yield fake
  end

  # Minimal agent double that returns a fixed result via _invoke_impl.
  def stub_agent(result: {output: "done", messages: [], usage: nil})
    agent = double("Agent")
    allow(agent).to receive(:send) do |meth, *args, **kwargs|
      expect(meth).to eq(:_invoke_impl)
      result
    end
    agent
  end

  describe "#initialize" do
    it "sets id to the provided thread_id" do
      fsm = described_class.new(agent: double, input: "hi", thread_id: "abc123")
      expect(fsm.id).to eq("abc123")
    end

    it "auto-generates a UUID id when thread_id is nil" do
      fsm = described_class.new(agent: double, input: "hi")
      expect(fsm.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "starts with :idle phase" do
      fsm = described_class.new(agent: double, input: "hi")
      expect(fsm.current_phase).to eq(:idle)
    end
  end

  describe "#start" do
    it "transitions current_phase to :running" do
      agent = stub_agent
      fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

      with_fake_loop do |fake|
        fsm.start
        sleep 0.1  # wait for IO thread
        expect(fsm.current_phase).to eq(:running)
      end
    end

    context "on successful agent completion" do
      it "posts :finished with result payload" do
        result = {output: "ok", messages: [], usage: nil}
        agent = stub_agent(result: result)
        fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

        with_fake_loop do |fake|
          fsm.start
          sleep 0.2  # wait for IO thread

          finished = fake.events.find { |e| e.type == :finished }
          expect(finished).not_to be_nil
          expect(finished.target_id).to eq("t1")
          expect(finished.payload).to eq(result)
        end
      end

      context "when parent_id is set" do
        it "posts :child_completed to parent_id before :finished" do
          result = {output: "child done", messages: [], usage: nil}
          agent = stub_agent(result: result)
          fsm = described_class.new(
            agent: agent, input: "hi", thread_id: "child_t",
            parent_id: "parent_t"
          )

          with_fake_loop do |fake|
            fsm.start
            sleep 0.2

            types = fake.events.map(&:type)
            expect(types).to include(:child_completed)
            expect(types).to include(:finished)
            expect(types.index(:child_completed)).to be < types.index(:finished)

            child_ev = fake.events.find { |e| e.type == :child_completed }
            expect(child_ev.target_id).to eq("parent_t")
            expect(child_ev.payload).to eq(result)
          end
        end
      end

      context "when parent_id is nil" do
        it "does not post :child_completed" do
          agent = stub_agent
          fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

          with_fake_loop do |fake|
            fsm.start
            sleep 0.2

            types = fake.events.map(&:type)
            expect(types).not_to include(:child_completed)
          end
        end
      end
    end

    context "when the agent raises" do
      it "posts :error with the exception as payload" do
        error = RuntimeError.new("boom")
        agent = double("Agent")
        allow(agent).to receive(:send).and_raise(error)

        fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

        with_fake_loop do |fake|
          fsm.start
          sleep 0.2

          err_ev = fake.events.find { |e| e.type == :error }
          expect(err_ev).not_to be_nil
          expect(err_ev.target_id).to eq("t1")
          expect(err_ev.payload).to eq(error)
        end
      end
    end

    it "sets the :phronomy_agent_parallel_tools thread-local flag inside the IO thread" do
      flag_value = nil
      agent = double("Agent")
      allow(agent).to receive(:send) do |meth, *_args, **_kwargs|
        flag_value = Thread.current[:phronomy_agent_parallel_tools] if meth == :_invoke_impl
        {output: "done", messages: [], usage: nil}
      end

      fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

      with_fake_loop do |_fake|
        fsm.start
        sleep 0.2
        expect(flag_value).to be true
      end
    end
  end

  describe "#handle" do
    it "is a no-op (does not raise)" do
      fsm = described_class.new(agent: double, input: "hi")
      expect { fsm.handle(double("event")) }.not_to raise_error
    end
  end
end
