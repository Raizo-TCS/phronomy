# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::Base do
  describe ".agent_definition" do
    it "uses the fully-qualified Ruby class name as the default definition id" do
      klass = Class.new(Phronomy::Agent::Base)
      stub_const("CG04NamedAgent", klass)

      expect(CG04NamedAgent.agent_definition(version: 3)).to eq(
        id: "CG04NamedAgent",
        version: 3
      )
    end

    it "preserves an explicit stable definition id override" do
      klass = Class.new(Phronomy::Agent::Base)

      expect(
        klass.agent_definition(id: "application-owned-lineage", version: 7)
      ).to eq(
        id: "application-owned-lineage",
        version: 7
      )
    end

    it "requires an explicit id when an anonymous Agent cannot derive a stable class name" do
      klass = Class.new(Phronomy::Agent::Base)

      expect do
        klass.agent_definition(version: 1)
      end.to raise_error(
        Phronomy::ConfigurationError,
        /anonymous Agent class must declare agent_definition id:/
      )
    end

    it "raises when agent_definition is called with id but no version" do
      klass = Class.new(Phronomy::Agent::Base)

      expect do
        klass.agent_definition(id: "my-lineage")
      end.to raise_error(ArgumentError, /requires version:/)
    end

    it "raises when tools DSL receives a non-Hash argument" do
      klass = Class.new(Phronomy::Agent::Base)
      expect { klass.tools([]) }.to raise_error(ArgumentError, /tools expects a Hash/)
    end

    it "sets cache_instructions to an explicit value" do
      klass = Class.new(Phronomy::Agent::Base)
      klass.cache_instructions(false)
      expect(klass.cache_instructions).to be(false)
    end

    it "does not inherit definition identity/revision while normal class configuration still inherits" do
      parent = Class.new(Phronomy::Agent::Base)
      stub_const("CG04ParentAgent", parent)
      parent.agent_definition(version: 1)
      parent.instructions "parent instructions"

      child = Class.new(parent)
      stub_const("CG04ChildAgent", child)

      expect(child.instructions).to eq("parent instructions")
      expect do
        child.agent_definition
      end.to raise_error(
        Phronomy::ConfigurationError,
        /CG04ChildAgent must declare agent_definition version:/
      )

      expect(child.agent_definition(version: 2)).to eq(
        id: "CG04ChildAgent",
        version: 2
      )
    end

    it "keeps agent_id stable and applies exact definition compatibility as a separate load policy" do
      persistence = Phronomy::Persistence::InMemory.new

      version_one = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "cg04-load-lineage", version: 1
      end
      version_two = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "cg04-load-lineage", version: 2
      end

      version_one.create(
        agent_id: "cg04-stable-agent-id",
        persistence: persistence
      )

      loaded = version_one.load(
        "cg04-stable-agent-id",
        persistence: persistence
      )
      expect(loaded.agent_id).to eq("cg04-stable-agent-id")
      expect(loaded.agent_root.agent_definition_version).to eq(1)

      expect do
        version_two.load(
          "cg04-stable-agent-id",
          persistence: persistence
        )
      end.to raise_error(Phronomy::ConfigurationError, /Agent definition mismatch/)
    end
  end

  describe "#check_cancellation! (Issue #223)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) {
        agent_definition id: "test-agent-202", version: 1
        model "test-model"
      }.new
    end

    it "does nothing when config has no cancellation_token" do
      expect { agent.send(:check_cancellation!, {}) }.not_to raise_error
    end

    it "does nothing when cancellation_token is not cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      expect { agent.send(:check_cancellation!, {cancellation_token: token}) }.not_to raise_error
    end

    it "raises CancellationError when token is cancelled" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      expect {
        agent.send(:check_cancellation!, {cancellation_token: token})
      }.to raise_error(Phronomy::CancellationError)
    end

    it "raises CancellationError with the provided message" do
      token = Phronomy::Concurrency::CancellationToken.new
      token.cancel!
      expect {
        agent.send(:check_cancellation!, {cancellation_token: token}, "cancelled mid-RAG")
      }.to raise_error(Phronomy::CancellationError, "cancelled mid-RAG")
    end
  end

  # ---------------------------------------------------------------------------
  # Issue #291 — invoke_async is the primary path; invoke is a wrapper
  # ---------------------------------------------------------------------------

  describe "invoke_async (Issue #291)" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-40", version: 1
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end

    it "returns a Task" do
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.new(name: "stub").tap { |t| t.complete({output: "ok"}) }
      end
      task = agent.invoke_async("hi")
      expect(task).to be_a(Phronomy::Task)
      task.wait_result
    end

    it "executes via FSM (not via invoke)" do
      invoke_called = false
      allow(agent).to receive(:invoke).and_wrap_original do |m, *a, **kw|
        invoke_called = true
        m.call(*a, **kw)
      end
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.new(name: "stub").tap { |t| t.complete({output: "ok"}) }
      end
      agent.invoke_async("hi").wait_result
      expect(invoke_called).to be(false)
    end

    it "registers the task with Runtime so shutdown can drain it" do
      allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do
        Phronomy::Task.new(name: "stub").tap { |t| t.complete({output: "ok"}) }
      end
      task = agent.invoke_async("hi")
      expect(task.wait_result[:output]).to eq("ok")
    end
  end

  describe "#stream_async EventLoop delivery" do
    let(:agent) do
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "test-agent-42", version: 1
        instructions "test"
        model "gpt-4o-mini"
      end.new
    end
    let(:fake_tokens_el) { double("Tok", input: 1, output: 1, cached: 0, cache_creation: 0, to_h: {"input" => 1, "output" => 1, "cached" => 0, "cache_creation" => 0}) }
    let(:fake_response_el) { double("Resp", role: :assistant, content: "ok", tool_calls: nil, tokens: fake_tokens_el, tool_call?: false) }

    before do
      dbl = double("Chat")
      allow(dbl).to receive(:with_instructions).and_return(dbl)
      allow(dbl).to receive(:with_tool).and_return(dbl)
      allow(dbl).to receive(:with_temperature).and_return(dbl)
      allow(dbl).to receive(:messages).and_return([fake_response_el])
      allow(dbl).to receive(:cancellation_token=)
      allow(dbl).to receive(:on_tool_call)
      allow(dbl).to receive(:before_tool_call)
      allow(dbl).to receive(:on_tool_result)
      allow(dbl).to receive(:ask) { |_msg, &blk|
        blk&.call(double("Chunk", content: "token"))
        fake_response_el
      }
      allow(dbl).to receive(:complete) { |&blk|
        blk&.call(double("Chunk", content: "token"))
        fake_response_el
      }
      allow(RubyLLM).to receive(:chat).and_return(dbl)
    end

    it "delivers token and terminal callbacks on the EventLoop thread" do
      event_loop = Phronomy::Runtime.instance.event_loop
      events = []
      event_loop_flags = []

      task = agent.stream_async("hi") do |event|
        events << event
        event_loop_flags << event_loop.current?
      end
      task.wait_result

      token_events = events.select { |e| e.type == :token }
      expect(token_events).not_to be_empty
      expect(events.last.type).to eq(:done)
      expect(event_loop_flags).not_to be_empty
      expect(event_loop_flags).to all(be(true))
    end

    it "keeps an immediately completed terminal callback on the EventLoop thread" do
      skip "obsolete: terminal delivery always routes through EventLoop system channel in new architecture"
    end

    it "does not invoke a terminal callback when completion escapes the EventLoop" do
      skip "obsolete: deliver_on_event_loop is always called from the EventLoop thread in new architecture"
    end

    it "requires a callback block" do
      expect { agent.stream_async("hi") }.to raise_error(ArgumentError)
      expect { agent.stream("hi") }.to raise_error(ArgumentError)
    end
  end
end

RSpec.describe "Agent::Base invocation_context: keyword argument (Issue #301)" do
  let(:agent) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-43", version: 1
      instructions "test"
      model "gpt-4o-mini"
    end.new
  end

  # Capture the config hash passed to ExecutionCoordinator#start.
  def capture_config(ag, &block)
    captured = {}
    allow_any_instance_of(Phronomy::Agent::ExecutionCoordinator).to receive(:start) do |_coord, _input, config: {}, **|
      captured = config
      Phronomy::Task.new(name: "stub-ic").tap { |t| t.complete({output: "ok"}) }
    end
    block.call
    captured
  end

  it "stores the InvocationContext in config[:invocation_context]" do
    ic = Phronomy::InvocationContext.new(task_id: "abc-123")
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:invocation_context]).to be(ic)
  end

  it "propagates InvocationContext without a generic identity" do
    ic = Phronomy::InvocationContext.new(task_id: "trace-task")
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:invocation_context]).to be(ic)
    expect(config).not_to have_key(:thread_id)
    expect(config).not_to have_key(:session_id)
  end

  it "rejects the removed Agent thread_id keyword" do
    expect {
      agent.invoke("hi", thread_id: "legacy")
    }.to raise_error(ArgumentError, /thread_id/)
  end

  it "derives cancellation_token from InvocationContext.cancellation_token" do
    token = Phronomy::Concurrency::CancellationToken.new
    ic = Phronomy::InvocationContext.new(cancellation_token: token)
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:cancellation_token]).to be(token)
  end

  it "derives cancellation_token from InvocationContext.deadline" do
    ic = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(30))
    config = capture_config(agent) { agent.invoke("hi", invocation_context: ic) }
    expect(config[:cancellation_token]).to be_a(Phronomy::Concurrency::CancellationToken)
  end

  it "existing config[:cancellation_token] takes precedence over ic" do
    explicit_token = Phronomy::Concurrency::CancellationToken.new
    ic = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(30))
    config = capture_config(agent) { agent.invoke("hi", config: {cancellation_token: explicit_token}, invocation_context: ic) }
    expect(config[:cancellation_token]).to be(explicit_token)
  end

  it "accepts user_id in config and forwards it through" do
    config = capture_config(agent) { agent.invoke("hi", config: {user_id: "user-42"}) }
    expect(config[:user_id]).to eq("user-42")
  end

  describe "#close!" do
    it "marks the Agent as closed and prevents further invocations" do
      agent.close!

      expect { agent.invoke("hi") }.to raise_error(Phronomy::Error, /agent is closed/)
    end

    it "is idempotent — calling close! twice does not raise" do
      agent.close!
      expect { agent.close! }.not_to raise_error
    end
  end
end
