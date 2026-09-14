# frozen_string_literal: true

require "spec_helper"
require "timeout"

class CompositionContractAgent < Phronomy::Agent::Base
  agent_definition id: "composition-contract-agent", version: 1
  model "test-model"
  instructions "Return an answer."
end

RSpec.describe "Execution with real Agent admission and terminal persistence" do
  def build_chat
    tokens = double("Tokens", input: 1, output: 1, cached: 0, cache_creation: 0,
      to_h: {input: 1, output: 1, cached: 0, cache_creation: 0})
    response = double("Response", role: :assistant, content: "answer", tool_calls: nil,
      tokens: tokens, tool_call?: false)
    chat = double("Chat")
    [:with_instructions, :with_tool, :with_temperature].each do |method|
      allow(chat).to receive(method).and_return(chat)
    end
    allow(chat).to receive(:cancellation_token=) { |token| @adapter_tokens << token }
    allow(chat).to receive(:messages).and_return([response])
    [:on_tool_call, :before_tool_call, :on_tool_result].each { |method| allow(chat).to receive(method) }
    allow(chat).to receive(:ask) do |*_args, &block|
      @started << true
      @release.pop if @hold
      block&.call(double("Chunk", content: "answer"))
      response
    end
    chat
  end

  before do
    @started = Queue.new
    @release = Queue.new
    @adapter_tokens = Queue.new
    @hold = false
    allow(RubyLLM).to receive(:chat) { build_chat }
  end

  after do
    4.times { @release << true }
  end

  it "composes each Agent's final value while keeping its materialization listener" do
    events = Queue.new
    agents = Array.new(2) { CompositionContractAgent.new { |event| events << event.type } }
    result = Phronomy::Execution.run_async(agents, timeout: 2) do |agent, execution|
      agent.invoke_async("question", invocation_context: execution.invocation_context)
        .map { |response| response.fetch(:output).upcase }
    end
    expect(result.wait_result(timeout: 3).map(&:value)).to eq(["ANSWER", "ANSWER"])
    expect([events.pop, events.pop]).to eq([:done, :done])
  end

  [:whole, :individual].each do |cancelled_source|
    it "connects #{cancelled_source} cancellation without cancelling the other source" do
      @hold = true
      whole = Phronomy::Concurrency::CancellationToken.new
      individual = Phronomy::Concurrency::CancellationToken.new
      agent = CompositionContractAgent.new
      agent_result = nil
      combined = Phronomy::Execution.run_async([agent], cancellation_token: whole) do |input, execution|
        agent_result = input.invoke_async("question", config: {cancellation_token: individual},
          invocation_context: execution.invocation_context)
        agent_result.map { |response| response.fetch(:output) }
      end
      Timeout.timeout(2) { @started.pop }
      ((cancelled_source == :whole) ? whole : individual).cancel!
      other = (cancelled_source == :whole) ? individual : whole
      expect(other).not_to be_cancelled
      # Physical LLM work may still be running. Releasing it permits the Agent's
      # existing durable terminal path to finish; Execution does not replace it.
      @release << true
      expect { agent_result.wait_result(timeout: 3) }.to raise_error(Phronomy::CancellationError)
      if cancelled_source == :whole
        expect { combined.wait_result(timeout: 3) }.to raise_error(Phronomy::ExecutionCancellationError) { |e|
          expect(e.outcomes.first.status).to eq(:unfinished)
        }
      else
        expect(combined.wait_result(timeout: 3).first.status).to eq(:cancelled)
      end
    end
  end

  it "does not admit a new Agent operation with a normally closed context" do
    context = nil
    Phronomy::Execution.run([1]) do |_, execution|
      context = execution.invocation_context
      Phronomy::TaskResult.completed(:done)
    end
    expect(RubyLLM).not_to receive(:chat)
    result = CompositionContractAgent.new.invoke_async("late", invocation_context: context)
    expect { result.wait_result(timeout: 2) }.to raise_error(Phronomy::CancellationError)
    expect(result.status).to eq(:cancelled)
  end
end
