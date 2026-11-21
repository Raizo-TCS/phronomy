# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Agent Tool invocation configuration" do
  let(:children) { [] }
  let(:configs) { [] }
  let(:requests) { [] }
  let(:responses) { [] }
  let(:child_gate) { nil }
  let(:child_class) do
    captured, submitted = children, configs
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "private-tool-child", version: 1
      model "offline-model"
      define_method(:initialize) do |**options|
        super(**options)
        captured << {agent: self, store: persistence}
      end
      define_method(:invoke_async) do |input, **options|
        submitted << options.fetch(:config).dup
        super(input, **options)
      end
    end
  end
  let(:tool_class) { Phronomy::Tools::Agent.from_agent(child_class, tool_name: "private_child") }
  let(:parent_class) do
    wrapped = tool_class
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "private-tool-parent", version: 1
      model "offline-model"
      tools wrapped => nil
    end
  end
  let(:parent) { parent_class.create }
  let(:schema) { {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false} }

  before do
    captured, pending, gate = requests, responses, child_gate
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |request, cancellation_token:|
        captured << request
        if gate && captured.length == 2
          gate.fetch(:entered) << cancellation_token
          gate.fetch(:release).pop(timeout: 5)
          cancellation_token&.raise_if_cancelled!
        end
        response = pending.shift || raise("unexpected provider replay")
        raise response if response.is_a?(Exception)
        response
      end
    end.new
    Phronomy.configure { |config| config.llm_adapter = adapter }
  end

  def response(text)
    Phronomy::LLMAdapter::Response.new(content: text, finish_reason: :stop)
  end

  def child_call
    Phronomy::LLMAdapter::Response.new(tool_calls: [
      Phronomy::Tool::CallRequest.new(id: "private-child-call", name: "private_child", arguments: {input: "detail"})
    ], finish_reason: :tool_calls)
  end

  def start_parent(entry, config: {}, **options)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: "reserved-parent-#{entry}")
    if entry == :invoke
      parent.invoke_async("delegate", config: config, **options)
    else
      method = (entry == :reserved) ? :start_reserved_async : :start_hosted
      parent.public_send(method, reservation: reservation, input: "delegate", config: config, **options)
    end
  end

  def saved_child
    entry = children.fetch(0)
    entry.fetch(:store).runs(entry.fetch(:agent).agent_id).fetch(0)
  end

  def expect_released
    expect(children.length).to eq(1)
    expect(child_class.get(children.first.fetch(:agent).agent_id)).to be_nil
    expect(parent_class.get(parent.agent_id)).to equal(parent)
    expect(Phronomy::Runtime.instance.state).to eq(:running)
  end

  %i[invoke reserved hosted].each do |entry|
    it "gives a fresh Tool child its own identity beneath #{entry}" do
      responses.replace([child_call, response("child-result"), response("parent-result")])
      context = Phronomy::InvocationContext.new(user_id: "caller", task_id: "app-request",
        deadline: Phronomy::Concurrency::Deadline.in(30))
      config = {:invocation_context => context, :durable_context => {"project" => "review"},
                :approval_context => {role: "reviewer"}, :authorization_timeout => 20,
                :application_setting => "preserved", "application_string_key" => "unchanged"}.freeze
      result = start_parent(entry, config: config).wait_result(timeout: 5)
      expect(result.fetch(:output)).to eq("parent-result")
      expect(saved_child.execution_id).not_to eq(result.fetch(:execution_id))
      expect(saved_child.status).to eq(:completed)
      expect(saved_child.metadata["reservation"]).to be_nil
      expect(configs.fetch(0)).to include(config)
      expect(configs.fetch(0).fetch(:invocation_context)).to equal(context)
      expect(configs.fetch(0).keys.grep(/^phronomy_/)).to be_empty
      expect(configs.fetch(0)).not_to have_key(:execution_id)
      expect(requests.length).to eq(3)
      expect_released
    end
  end

  it "excludes parent execution wiring even when a Tool is called directly" do
    responses << response("child-result")
    token = Phronomy::Concurrency::CancellationToken.new
    context = Phronomy::InvocationContext.new(user_id: "reviewer")
    deadline = Phronomy::Concurrency::Deadline.in(30)
    parent_wiring = %i[
      phronomy_admission phronomy_reservation phronomy_reserved_execution_id
      phronomy_exact_observers phronomy_execution_participant phronomy_control_bindings
      phronomy_transfer_context phronomy_execution_coordinator phronomy_runtime_projection
      phronomy_filtered_input phronomy_recovery_mode phronomy_tool_invocation_id
      phronomy_output_contract
    ].to_h { |key| [key, Object.new] }
    config = parent_wiring.merge(:execution_id => "parent-only", "phronomy_reservation" => Object.new,
      "execution_id" => "string-parent-only", :invocation_context => context,
      :application_option => "keep", "user_id" => "string-app-value", :phronomy_timeout_deadline => deadline).freeze
    expect(tool_class.new.call_async({input: "detail"}, config: config, cancellation_token: token).wait_result(timeout: 5))
      .to eq("child-result")
    expect(configs.fetch(0)).to eq(:invocation_context => context, :cancellation_token => token,
      :application_option => "keep", "user_id" => "string-app-value", :phronomy_timeout_deadline => deadline)
    expect(config).to include(parent_wiring)
    expect(saved_child.metadata["reservation"]).to be_nil
    expect(saved_child.metadata).not_to have_key("execution_extension")
    expect(child_class.get(children.first.fetch(:agent).agent_id)).to be_nil
  end

  it "keeps a reserved parent's output promise separate from the private child's output" do
    responses.replace([child_call, response("plain child answer"), response('{"answer":"parent answer"}')])
    result = start_parent(:reserved, output_schema: schema).wait_result(timeout: 5)
    expect(result.fetch(:output)).to eq("answer" => "parent answer")
    expect(requests.map { |request| !request.response_schema.nil? }).to eq([true, false, true])
    expect(saved_child.metadata).not_to have_key("output_contract")
    expect(parent.persistence.executions.load(result.fetch(:execution_id)).metadata).to have_key("output_contract")
    expect_released
  end

  it "keeps invalid public schema options invalid instead of silently filtering them" do
    [{output_schema: schema}, {schema_delivery: :none}, {response_schema: schema}].each do |config|
      task = tool_class.new.call_async({input: "detail"}, config: config)
      expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::ToolError) { |error|
        expect(error.cause).to be_a(ArgumentError)
      }
    end
    expect(children.length).to eq(3)
    expect(children.map { |entry| child_class.get(entry.fetch(:agent).agent_id) }).to all(be_nil)
    expect(requests).to be_empty
  end

  it "preserves the existing shared deadline check after a child's input hook" do
    child_class.before_llm_input { |_context| nil }
    deadline = Phronomy::Concurrency::Deadline.in(-1)
    task = tool_class.new.call_async({input: "detail"}, config: {phronomy_timeout_deadline: deadline})
    expect { task.wait_result(timeout: 5) }.to raise_error(Phronomy::ToolError) { |error|
      expect(error.cause).to be_a(Phronomy::TimeoutError)
    }
    expect(configs.first.fetch(:phronomy_timeout_deadline)).to equal(deadline)
    expect(requests).to be_empty
    expect(child_class.get(children.first.fetch(:agent).agent_id)).to be_nil
  end

  it "keeps a child failure scoped to the parent execution outcome" do
    responses.replace([child_call, Phronomy::LLMAdapter::TransportError.new("child provider failed")])
    result = start_parent(:reserved).wait_result(timeout: 5)
    expect(result.fetch(:status)).to eq(:failed)
    expect(result.fetch(:error)).to include("class" => "Phronomy::ToolError", "code" => "tool.execution_failed")
    expect(result.fetch(:error).fetch("cause")).to include("class" => "Phronomy::LLMAdapter::TransportError")
    expect(saved_child.status).to eq(:failed)
    expect(saved_child.execution_id).not_to eq(result.fetch(:execution_id))
    expect_released
  end

  context "when cancellation arrives during child provider work" do
    let(:child_gate) { {entered: Queue.new, release: Queue.new} }

    it "preserves a public InvocationContext deadline across the fresh-child boundary" do
      responses.replace([child_call, response("unused child response")])
      deadline_callbacks = []
      allow(Phronomy::Execution).to receive(:after).and_wrap_original do |original, seconds, &callback|
        deadline_callbacks << callback if seconds > 20 && seconds <= 30
        original.call(seconds, &callback)
      end
      context = Phronomy::InvocationContext.new(deadline: Phronomy::Concurrency::Deadline.in(30))
      handle = start_parent(:reserved, config: {invocation_context: context})
      child_token = child_gate.fetch(:entered).pop(timeout: 5)
      expect(child_token).not_to be_nil
      expect(deadline_callbacks).not_to be_empty
      physical = Queue.new
      handle.on_physical_complete { physical << true }
      # Deliver the already registered deadline after child entry instead of
      # relying on the machine reaching that state before a short wall timer.
      deadline_callbacks.first.call
      expect(child_token).to be_cancelled
      child_gate.fetch(:release) << true
      result = handle.wait_result(timeout: 5)
      expect(result.fetch(:status)).to eq(:cancelled)
      expect(physical.pop(timeout: 5)).to be(true)
      expect(saved_child.status).to eq(:cancelled)
      expect_released
    ensure
      child_gate.fetch(:release) << true
    end

    %i[config context].each do |source|
      it "preserves cancellation from the parent's #{source}" do
        responses.replace([child_call, response("unused child response")])
        token = Phronomy::Concurrency::CancellationToken.new
        config = if source == :config
          {cancellation_token: token}
        else
          {invocation_context: Phronomy::InvocationContext.new(cancellation_token: token)}
        end
        handle = start_parent(:reserved, config: config)
        child_token = child_gate.fetch(:entered).pop(timeout: 5)
        expect(child_token).not_to be_nil
        physical = Queue.new
        handle.on_physical_complete { physical << true }
        token.cancel!
        expect(child_token).to be_cancelled
        child_gate.fetch(:release) << true
        result = handle.wait_result(timeout: 5)
        expect(result.fetch(:status)).to eq(:cancelled)
        expect(physical.pop(timeout: 5)).to be(true)
        expect(saved_child.status).to eq(:cancelled)
        expect_released
      ensure
        child_gate.fetch(:release) << true
      end
    end
  end
end
