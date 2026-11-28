# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../../integration/support/llm_stub"

RSpec.describe Phronomy::MultiAgent::HandoffRunner, "exact turn resumption" do
  let(:stores) { Phronomy::PersistenceComposition.in_memory }
  let(:source_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "exact-handoff-source", version: 1
      model "gpt-4o-mini"
      provider :openai
    end
  end
  let(:target_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "exact-handoff-target", version: 1
      model "gpt-4o-mini"
      provider :openai
    end
  end
  let(:source) { source_class.create(persistence: stores.agent) }
  let(:target) { target_class.create(persistence: stores.agent) }
  let(:edge) { Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target) }
  let(:runner) { described_class.new(main_agent: source, persistence: stores.multi_agent, handoffs: [edge]) }

  before { RubyLLM.configure { |config| config.openai_api_key = "test" } }
  after { LLMStub.deactivate }

  def transfer_response(handoff = edge)
    name = Phronomy::MultiAgent::HandoffCapabilityFactory.build(handoff).tool_name
    LLMStub.tool_call_response(name, {responsibility: "Finish the original case"})
  end

  def suspend_before_target
    first = true
    allow(target).to receive(:start_reserved_async).and_wrap_original do |original, **arguments|
      if first
        first = false
        raise IOError, "Target start was not submitted"
      end
      original.call(**arguments)
    end
    expect { runner.invoke("original case") }.to raise_error(IOError, /not submitted/)
    stores.multi_agent.handoff_states.load(source.agent_id)
  end

  def replace_route(**changes)
    stores.multi_agent.transaction do |records, _scope|
      state = records.handoff_states.load_locked(source.agent_id)
      records.handoff_states.save(source.agent_id, expected_revision: state.handoff_revision, state: state.with(**changes))
    end
  end

  it "returns the saved direct result without creating another execution" do
    recorder = LLMStub.activate(responses: ["direct result"])
    original = runner.invoke("original case")
    resumed = runner.resume(original.fetch(:execution_id))
    expect(resumed).to include(execution_id: original.fetch(:execution_id), agent_id: source.agent_id,
      status: :completed, result: "direct result", output: "direct result", error: nil, agent: source)
    expect(recorder.calls.size).to eq(1)
  end

  it "continues the exact reserved Target from the saved Source chain" do
    recorder = LLMStub.activate(responses: [transfer_response, "target result"])
    state = suspend_before_target
    expect(runner.result(state.pending_source_execution_id)).to include(execution_id: state.pending_target_execution_id, reserved: true)
    resumed = runner.resume(state.pending_source_execution_id)
    expect(resumed).to include(execution_id: state.pending_target_execution_id, agent: target, output: "target result")
    expect(runner.resume(state.pending_source_execution_id)).to eq(resumed)
    expect(recorder.calls.size).to eq(2)
  end

  it "joins the exact active Target after the earlier Runner observation fails" do
    recorder = LLMStub.activate(responses: [transfer_response, "target result"])
    reached = Queue.new
    release = Queue.new
    joined = Queue.new
    allow(recorder).to receive(:handle).and_wrap_original do |original, request|
      if recorder.calls.size == 1
        reached << true
        release.pop
      end
      original.call(request)
    end
    allow(target).to receive(:start_reserved_async).and_wrap_original do |original, **arguments|
      original.call(**arguments).tap do |task|
        allow(task).to receive(:wait_result).and_raise(IOError, "Runner observation lost")
      end
    end
    expect { runner.invoke("original case") }.to raise_error(IOError, /observation lost/)
    Timeout.timeout(5) { reached.pop }
    state = stores.multi_agent.handoff_states.load(source.agent_id)
    allow(target).to receive(:resume_async).and_wrap_original do |original, *arguments, **options|
      original.call(*arguments, **options).tap { joined << true }
    end
    resumed = Thread.new { runner.resume(state.pending_source_execution_id) }
    begin
      Timeout.timeout(5) { joined.pop }
    ensure
      release << true
      Timeout.timeout(5) { resumed.join }
    end
    expect(resumed.value).to include(execution_id: state.pending_target_execution_id, output: "target result", agent: target)
    expect(recorder.calls.size).to eq(2)
  end

  it "returns the old chain after another turn has completed on its Agent" do
    recorder = LLMStub.activate(responses: [transfer_response, "old result", "new result"])
    first = runner.invoke("old case")
    anchor = stores.multi_agent.handoff_states.load(source.agent_id).pending_source_execution_id
    second = runner.invoke("new case")
    expect(second.fetch(:execution_id)).not_to eq(first.fetch(:execution_id))
    expect(runner.resume(anchor)).to include(execution_id: first.fetch(:execution_id), output: "old result", agent: target)
    expect(runner.result(second.fetch(:execution_id))).to include(output: "new result")
    expect(recorder.calls.size).to eq(3)
  end

  it "observes historical completion without acquiring another active turn's admission" do
    recorder = LLMStub.activate(responses: ["old result", "new result"])
    first = runner.invoke("old case")
    reached = Queue.new
    release = Queue.new
    allow(recorder).to receive(:handle).and_wrap_original do |original, request|
      reached << true
      release.pop
      original.call(request)
    end
    current = Thread.new { runner.invoke("new case") }
    Timeout.timeout(5) { reached.pop }
    begin
      expect(runner.resume(first.fetch(:execution_id))).to include(execution_id: first.fetch(:execution_id), output: "old result")
    ensure
      release << true
      Timeout.timeout(5) { current.join }
    end
    expect(current.value.fetch(:output)).to eq("new result")
    expect(recorder.calls.size).to eq(2)
  end

  it "continues more than one newly driven transfer without changing the original anchor" do
    last = target_class.create(persistence: stores.agent)
    second_edge = Phronomy::MultiAgent::Handoff.new(source_agent: target, target_agent: last)
    selected = described_class.new(main_agent: source, persistence: stores.multi_agent, handoffs: [edge, second_edge])
    recorder = LLMStub.activate(responses: [transfer_response, transfer_response(second_edge), "last result"])
    first = true
    allow(target).to receive(:start_reserved_async).and_wrap_original do |original, **arguments|
      if first
        first = false
        raise IOError, "Target not submitted"
      end
      original.call(**arguments)
    end
    expect { selected.invoke("case") }.to raise_error(IOError, /not submitted/)
    anchor = stores.multi_agent.handoff_states.load(source.agent_id).pending_source_execution_id
    result = selected.resume(anchor)
    expect(result).to include(agent: last, output: "last result")
    expect(selected.resume(anchor)).to eq(result)
    expect(recorder.calls.size).to eq(3)
  end

  it "limits newly driven transfers without counting the already saved chain again" do
    stub_const("Phronomy::MultiAgent::HandoffRunner::MAX_HANDOFFS", 1)
    third = target_class.create(persistence: stores.agent)
    fourth = target_class.create(persistence: stores.agent)
    second_edge = Phronomy::MultiAgent::Handoff.new(source_agent: target, target_agent: third)
    third_edge = Phronomy::MultiAgent::Handoff.new(source_agent: third, target_agent: fourth)
    selected = described_class.new(main_agent: source, persistence: stores.multi_agent, handoffs: [edge, second_edge, third_edge])
    recorder = LLMStub.activate(responses: [transfer_response, transfer_response(second_edge), transfer_response(third_edge), "fourth result"])
    first = true
    allow(target).to receive(:start_reserved_async).and_wrap_original do |original, **arguments|
      if first
        first = false
        raise IOError, "Target not submitted"
      end
      original.call(**arguments)
    end
    expect { selected.invoke("case") }.to raise_error(IOError, /not submitted/)
    anchor = stores.multi_agent.handoff_states.load(source.agent_id).pending_source_execution_id
    expect { selected.resume(anchor) }.to raise_error(Phronomy::HandoffError, /continuation segment/)
    expect(recorder.calls.size).to eq(3)
    expect(selected.resume(anchor)).to include(agent: fourth, output: "fourth result")
    expect(recorder.calls.size).to eq(4)
  end

  it "propagates a job cancellation token without starting the reserved Target" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    expect { runner.resume(state.pending_source_execution_id, config: {cancellation_token: token}) }.to raise_error(Phronomy::CancellationError)
    expect(runner.result(state.pending_source_execution_id)).to include(status: :cancelled, execution_id: state.pending_target_execution_id)
    expect(recorder.calls.size).to eq(1)
  end

  it "rejects an execution from another Handoff anchor without Provider work" do
    recorder = LLMStub.activate(responses: ["other result"])
    other = target_class.create(persistence: stores.agent)
    other_runner = described_class.new(main_agent: other, persistence: stores.multi_agent)
    result = other_runner.invoke("other case")
    runner.invoke("own case")
    expect { runner.resume(result.fetch(:execution_id)) }.to raise_error(Phronomy::Persistence::StateConflictError, /anchor/)
    expect(recorder.calls.size).to eq(2)
  end

  it "rejects a pending Target when routing names a different execution" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    replace_route(pending_target_execution_id: "another-reservation")
    expect { runner.resume(state.pending_source_execution_id) }.to raise_error(Phronomy::Persistence::StateConflictError, /identity/)
    expect(recorder.calls.size).to eq(1)
  end

  it "rejects a pending Target when routing no longer agrees with the captured context" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    replace_route(active_handoff_context_ref: "another-context")
    expect { runner.resume(state.pending_source_execution_id) }.to raise_error(Phronomy::Persistence::StateConflictError, /receipt/)
    expect(recorder.calls.size).to eq(1)
  end

  it "rejects a pending Target when the saved definition no longer agrees" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    replace_route(metadata: state.metadata.merge("target_definition" => {"id" => "other", "version" => 1}))
    expect { runner.resume(state.pending_source_execution_id) }.to raise_error(Phronomy::ConfigurationError, /definition/)
    expect(recorder.calls.size).to eq(1)
  end

  it "rejects a graph without the saved Source to Target edge" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    reversed = Phronomy::MultiAgent::Handoff.new(source_agent: target, target_agent: source)
    changed = described_class.new(main_agent: source, persistence: stores.multi_agent, handoffs: [reversed])
    expect { changed.resume(state.pending_source_execution_id) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /edge/)
    expect(recorder.calls.size).to eq(1)
  end

  it "rejects a missing Target hold before admission" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    stores.multi_agent.transaction do |_records, scope|
      stores.agent.release_retention(agent_id: target.agent_id, owner_key: "handoff:#{source.agent_id}", scope: scope)
    end
    expect { runner.resume(state.pending_source_execution_id) }.to raise_error(Phronomy::Persistence::StateConflictError, /retains/)
    expect(recorder.calls.size).to eq(1)
  end

  it "does not admit a cancelled absent Target or rewrite its cancellation" do
    recorder = LLMStub.activate(responses: [transfer_response, "unused"])
    state = suspend_before_target
    runner.cancel(state.pending_source_execution_id)
    cancelled = stores.multi_agent.handoff_states.load(source.agent_id)
    expect { runner.resume(state.pending_source_execution_id) }.to raise_error(Phronomy::CancellationError, /cancelled/)
    expect(stores.multi_agent.handoff_states.load(source.agent_id).to_h).to eq(cancelled.to_h)
    expect(recorder.calls.size).to eq(1)
  end

  it "keeps saved failure semantics instead of starting another attempt" do
    LLMStub.activate(responses: ["unused"])
    completed = runner.invoke("case")
    observed = stores.agent.observe_execution(agent_id: source.agent_id, execution_id: completed.fetch(:execution_id))
    failure = observed.with(status: :failed, error: {"class" => "StandardError", "message" => "saved failure"})
    allow(stores.multi_agent).to receive(:handoff_leaf).with(completed.fetch(:execution_id), main_agent_id: source.agent_id).and_return(failure)
    expect(source).not_to receive(:resume_async)
    expect { runner.resume(completed.fetch(:execution_id)) }.to raise_error(StandardError, /saved failure/)
  end

  it "rejects resumption in a different Runtime before reading or starting work" do
    selected = runner
    Phronomy::Runtime.instance.shutdown
    Phronomy::Runtime.restore_default_for_test(nil)
    expect(stores.multi_agent).not_to receive(:transaction)
    expect { selected.resume("old-execution") }.to raise_error(Phronomy::RuntimeShutdownError, /previous Runtime/)
  end

  it "rejects an empty exact execution identity" do
    expect { runner.resume("") }.to raise_error(ArgumentError, /nonempty/)
  end
end
