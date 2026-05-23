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

        it "calls result_writer with the result before posting :child_completed" do
          result = {output: "child done", messages: [], usage: nil}
          agent = stub_agent(result: result)
          written = nil
          writer_called_at = nil
          child_completed_at = nil

          fsm = described_class.new(
            agent: agent, input: "hi", thread_id: "child_t",
            parent_id: "parent_t",
            result_writer: ->(r) {
              written = r
              writer_called_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
            }
          )

          with_fake_loop do |fake|
            # Intercept the moment :child_completed is received by the fake loop
            allow(fake).to receive(:post).and_wrap_original do |m, ev|
              child_completed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) if ev.type == :child_completed
              m.call(ev)
            end

            fsm.start
            sleep 0.2

            expect(written).to eq(result)
            expect(writer_called_at).not_to be_nil
            expect(child_completed_at).not_to be_nil
            # writer must be called strictly before :child_completed is posted
            expect(writer_called_at).to be <= child_completed_at
          end
        end

        it "does not raise when result_writer is nil" do
          result = {output: "no writer", messages: [], usage: nil}
          agent = stub_agent(result: result)
          fsm = described_class.new(
            agent: agent, input: "hi", thread_id: "child_t",
            parent_id: "parent_t", result_writer: nil
          )

          with_fake_loop do |fake|
            expect { fsm.start }.not_to raise_error
            sleep 0.2
            expect(fake.events.map(&:type)).to include(:child_completed)
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

      context "when parent_id is set" do
        it "posts :child_failed to parent_id with the exception" do
          error = RuntimeError.new("child boom")
          agent = double("Agent")
          allow(agent).to receive(:send).and_raise(error)

          fsm = described_class.new(
            agent: agent, input: "hi", thread_id: "child_t",
            parent_id: "parent_t"
          )

          with_fake_loop do |fake|
            fsm.start
            sleep 0.2

            fail_ev = fake.events.find { |e| e.type == :child_failed }
            expect(fail_ev).not_to be_nil
            expect(fail_ev.target_id).to eq("parent_t")
            expect(fail_ev.payload).to eq(error)
          end
        end

        it "still posts :error to the child fsm_id" do
          error = RuntimeError.new("child boom")
          agent = double("Agent")
          allow(agent).to receive(:send).and_raise(error)

          fsm = described_class.new(
            agent: agent, input: "hi", thread_id: "child_t",
            parent_id: "parent_t"
          )

          with_fake_loop do |fake|
            fsm.start
            sleep 0.2

            err_ev = fake.events.find { |e| e.type == :error }
            expect(err_ev).not_to be_nil
            expect(err_ev.target_id).to eq("child_t")
          end
        end

        it "posts :child_failed when result_writer raises" do
          result = {output: "ok", messages: [], usage: nil}
          agent = stub_agent(result: result)
          error = RuntimeError.new("writer error")

          fsm = described_class.new(
            agent: agent, input: "hi", thread_id: "child_t",
            parent_id: "parent_t",
            result_writer: ->(_r) { raise error }
          )

          with_fake_loop do |fake|
            fsm.start
            sleep 0.2

            fail_ev = fake.events.find { |e| e.type == :child_failed }
            expect(fail_ev).not_to be_nil
            expect(fail_ev.target_id).to eq("parent_t")
            expect(fail_ev.payload).to eq(error)
          end
        end
      end

      context "when parent_id is nil" do
        it "does not post :child_failed" do
          error = RuntimeError.new("boom")
          agent = double("Agent")
          allow(agent).to receive(:send).and_raise(error)

          fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

          with_fake_loop do |fake|
            fsm.start
            sleep 0.2

            types = fake.events.map(&:type)
            expect(types).not_to include(:child_failed)
          end
        end
      end
    end

    it "runs the agent pipeline in a Task (not a raw Thread)" do
      task_spawned = false
      agent = double("Agent")
      allow(agent).to receive(:send).and_return({output: "done", messages: [], usage: nil})
      allow(agent).to receive(:class).and_return(double(respond_to?: false))

      fsm = described_class.new(agent: agent, input: "hi", thread_id: "t1")

      allow(Phronomy::Task).to receive(:spawn).and_wrap_original do |orig, **kw, &blk|
        task_spawned = true
        orig.call(**kw, &blk)
      end

      with_fake_loop do |_fake|
        fsm.start
        sleep 0.2
        expect(task_spawned).to be true
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
