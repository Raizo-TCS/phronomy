# frozen_string_literal: true

require "spec_helper"

unless defined?(HITLTool)
  class HITLTool < Phronomy::Tool::Base
    tool_name "hitl_tool"
    description "A tool requiring human approval"
    requires_approval true
    param :value, type: :string, desc: "Input"
    def execute(value:) = "executed: #{value}"
  end
end

unless defined?(HITLAgentForApproveAsync)
  class HITLAgentForApproveAsync < Phronomy::Agent::Base
    agent_definition id: "hitl-agent-approve-async", version: 1
    model "test-model"
    instructions "You are a test assistant."
    tools HITLTool => nil
  end
end

FAKE_APPROVE_ASYNC_TOKENS = Struct.new(:input, :output, :cache_read, :cache_write).new(10, 5, 0, 0)

def build_approve_async_chat(tool_instance:, final_response: "resumed")
  stored_hook = nil
  fake_tc = double(
    "ToolCall",
    name: "hitl_tool",
    arguments: {"value" => "hello"},
    id: "call_001",
    thought_signature: nil,
    to_h: {id: "call_001", name: "hitl_tool", arguments: {"value" => "hello"}}
  )
  fake_assistant_msg = double(
    "AssistantMessage",
    role: :assistant,
    content: nil,
    tool_calls: [fake_tc],
    tokens: FAKE_APPROVE_ASYNC_TOKENS,
    tool_call?: true
  )
  final_resp = double("FinalResp", role: :assistant, content: final_response, tokens: FAKE_APPROVE_ASYNC_TOKENS)
  dbl = double("HITLChat")
  allow(dbl).to receive(:with_instructions).and_return(dbl)
  allow(dbl).to receive(:with_tools).and_return(dbl)
  allow(dbl).to receive(:with_temperature).and_return(dbl)
  allow(dbl).to receive(:messages) { [fake_assistant_msg] }
  allow(dbl).to receive(:tools) { {hitl_tool: tool_instance} }
  allow(dbl).to receive(:add_message)
  allow(dbl).to receive(:cancellation_token=)
  allow(dbl).to receive(:on_tool_call) { |&block| stored_hook = block }
  allow(dbl).to receive(:after_message) { |&block| stored_hook = block }
  allow(dbl).to receive(:on_tool_result)
  allow(dbl).to receive(:ask) { stored_hook&.call(fake_assistant_msg) }
  allow(dbl).to receive(:complete).and_return(final_resp)
  dbl
end

RSpec.describe Phronomy::Agent::Base do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "test-agent-38", version: 1
      instructions "test"
      model "gpt-4o-mini"
    end
  end
  let(:agent) { agent_class.new }

  after do
    Phronomy.reset_runtime!
  rescue
    nil
  end

  describe "#approve EventLoop re-entry guard" do
    it "raises EventLoopReentrancyError when called from the EventLoop thread" do
      agent
      event_loop = Phronomy::Runtime.instance.event_loop
      allow(Phronomy::WaitPolicy).to receive(:blocking_forbidden?).and_return(true)

      expect do
        agent.approve(
          "invocation-1",
          approval_request_id: "request-1",
          approved: true
        )
      end.to raise_error(
        Phronomy::EventLoopReentrancyError,
        /approve_async/
      )
    ensure
      allow(event_loop).to receive(:current?).and_call_original if event_loop
    end
  end

  describe "#approve_async" do
    let(:tool_instance) { HITLTool.new }
    let(:approvals) { Queue.new }
    let(:agent) do
      HITLAgentForApproveAsync.new(
        on_event: ->(event) {
          approvals << event.payload.fetch(:request) if event.type == :approval_required
        }
      )
    end
    let(:chat) { build_approve_async_chat(tool_instance: tool_instance) }

    before { allow(RubyLLM).to receive(:chat).and_return(chat) }

    def invoke_and_suspend(agent, approvals)
      original = agent.invoke_async("run tool")
      [original, approvals.pop]
    end

    context "exact resume cancellation delivery" do
      [:before_delivery, :during_delivery].each do |timing|
        [false, true].each do |write_fails|
          it "records #{timing} cancellation before signaling, write_fails=#{write_fails}" do
            live_token = Phronomy::Concurrency::CancellationToken.new
            agent.invoke_async("run tool", config: {cancellation_token: live_token})
            request = approvals.pop(timeout: 5)
            expect(request).not_to be_nil
            id = request.execution_id
            before = agent.persistence.executions.load(id)
            incoming = Phronomy::Concurrency::CancellationToken.new
            registry = agent.__execution_environment.registry
            delivery_threads = Queue.new
            record_threads = Queue.new
            order = Queue.new
            injected = false

            # Change only the caller's token, at a legal point in delivery.
            # The real registry, EventLoop, owner and durable records are used.
            allow(Phronomy::Agent::ExactExecution).to receive(:new).and_wrap_original do |constructor, *args|
              observer = constructor.call(*args)
              allow(observer).to receive(:deliver_on_event_loop).and_wrap_original do |deliver, command|
                previous = Thread.current[:exact_cancellation_test_delivery]
                Thread.current[:exact_cancellation_test_delivery] = true
                delivery_threads << Phronomy::Runtime.instance.event_loop.current?
                begin
                  if timing == :before_delivery && !injected
                    injected = true
                    incoming.cancel!
                  end
                  deliver.call(command)
                ensure
                  Thread.current[:exact_cancellation_test_delivery] = previous
                end
              end
              observer
            end
            allow(registry).to receive(:agent_execution_state).and_wrap_original do |read, execution_id|
              state = read.call(execution_id)
              if timing == :during_delivery && Thread.current[:exact_cancellation_test_delivery] && execution_id == id && !injected
                injected = true
                incoming.cancel!
              end
              state
            end
            allow(agent.persistence).to receive(:request_cancellation).and_wrap_original do |record, **args|
              record_threads << Phronomy::Runtime.instance.event_loop.current?
              expect(live_token).not_to be_cancelled
              raise IOError, "cancellation recording unavailable" if write_fails
              record.call(**args).tap { order << :recorded }
            end
            allow(live_token).to receive(:cancel!).and_wrap_original do |cancel|
              order << :signaled
              cancel.call
            end
            expected = write_fails ? IOError : Phronomy::ExecutionRehydrationRequiredError
            expect { agent.resume_async(id, config: {cancellation_token: incoming}).wait_result(timeout: 5) }
              .to raise_error(expected)
            expect(injected).to be(true)
            expect(incoming).to be_cancelled
            expect(delivery_threads.size).to be >= 1
            expect(delivery_threads.size.times.map { delivery_threads.pop }).to all(be(true))
            expect(record_threads.pop(timeout: 1)).to be(false)
            expect(live_token.cancelled?).to eq(!write_fails)
            expect(agent.persistence.cancellation_requested?(agent_id: agent.agent_id, execution_id: id)).to eq(!write_fails)
            expect(order.size.times.map { order.pop }).to eq(write_fails ? [] : [:recorded, :signaled])
            expect(agent.persistence.executions.load(id).to_h).to eq(before.to_h)
          end
        end
      end
    end

    it "invalidates suspended execution waiters through Agent cleanup after the loop joins" do
      original, request = invoke_and_suspend(agent, approvals)
      runtime = Phronomy::Runtime.instance
      event_loop = runtime.event_loop
      registry = Phronomy::Agent::ExecutionRegistry.existing_for(runtime)
      cleanup_context = nil
      allow(registry).to receive(:shutdown).and_wrap_original do |method, **args|
        cleanup_context = [event_loop.current?, event_loop.thread_alive?]
        method.call(**args)
      end

      expect(runtime.shutdown(timeout: 3)).to be_cleanup_complete
      expect(cleanup_context).to eq([false, false])
      expect { original.wait_result(timeout: 1) }
        .to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      expect(registry.agent_execution_owner(request.execution_id)).to be_nil
      expect(registry.agent_execution_admitted?(agent.agent_id)).to be(false)
    end

    it "returns a distinct pending TaskResult that joins the same terminal execution" do
      original, request = invoke_and_suspend(agent, approvals)
      allow(tool_instance).to receive(:call).and_return("done")

      task = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id
      )
      expect(task).to be_a(Phronomy::TaskResult)
      expect(task).not_to equal(original)

      approval_result = task.wait_result
      original_result = original.wait_result
      expect(approval_result[:output]).to eq("resumed")
      expect(original_result[:output]).to eq("resumed")
      expect(approval_result[:execution_id]).to eq(original_result[:execution_id])
    end

    it "resumes the same live Agent owner without exposing mutable Runtime state" do
      original, request = invoke_and_suspend(agent, approvals)
      owner = Phronomy::Agent::ExecutionRegistry.existing_for(Phronomy::Runtime.instance)&.agent_execution_owner(request.execution_id)

      expect(owner.agent).to be(agent)
      expect(owner.status).to eq(:suspended)
      expect(owner).not_to respond_to(:invocation)
      expect(owner).not_to respond_to(:execution)

      allow(tool_instance).to receive(:call).and_return("done")
      agent.approve_async(
        request.execution_id,
        approval_request_id: request.id
      ).wait_result
      expect(original.wait_result[:output]).to eq("resumed")
    end

    it "is callable while the EventLoop is current" do
      original, request = invoke_and_suspend(agent, approvals)
      allow(tool_instance).to receive(:call).and_return("done")

      Phronomy::Runtime.instance.event_loop
      allow(Phronomy::WaitPolicy).to receive(:blocking_forbidden?).and_return(true)

      task = agent.approve_async(
        request.execution_id,
        approval_request_id: request.id
      )
      expect(task).to be_a(Phronomy::TaskResult)

      allow(Phronomy::WaitPolicy).to receive(:blocking_forbidden?).and_call_original
      expect(task.wait_result[:output]).to eq("resumed")
      expect(original.wait_result[:output]).to eq("resumed")
    end

    it "returns a failed TaskResult requiring durable rehydration when execution_id has no live owner" do
      task = agent.approve_async("nonexistent-exec", approval_request_id: "none")
      expect(task).to be_a(Phronomy::TaskResult)
      expect { task.wait_result }
        .to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    end

    it "fails only the approval TaskResult when another Agent instance attempts resume" do
      original, request = invoke_and_suspend(agent, approvals)
      other = HITLAgentForApproveAsync.new

      task = other.approve_async(
        request.execution_id,
        approval_request_id: request.id
      )

      expect { task.wait_result }.to raise_error(
        ArgumentError,
        /not a suspended execution of this agent/
      )
      expect(original).not_to be_done
      expect(Phronomy::Agent::ExecutionRegistry.existing_for(Phronomy::Runtime.instance)&.agent_execution_owner(request.execution_id)&.status)
        .to eq(:suspended)

      allow(tool_instance).to receive(:call).and_return("done")
      agent.approve_async(
        request.execution_id,
        approval_request_id: request.id
      ).wait_result
      expect(original.wait_result[:output]).to eq("resumed")
    end
  end

  describe ".live_for_execution" do
    let(:tool_instance) { HITLTool.new }
    let(:persistence) { Phronomy::PersistenceComposition.in_memory.agent }
    let(:approvals) { Queue.new }
    let(:agent) do
      HITLAgentForApproveAsync.new(
        persistence: persistence,
        on_event: ->(event) {
          approvals << event.payload.fetch(:request) if event.type == :approval_required
        }
      )
    end
    let(:chat) { build_approve_async_chat(tool_instance: tool_instance) }

    before { allow(RubyLLM).to receive(:chat).and_return(chat) }

    def invoke_and_suspend(agent, approvals)
      original = agent.invoke_async("run tool")
      [original, approvals.pop]
    end

    it "returns the same live owner Agent through Agent::Base" do
      _original, request = invoke_and_suspend(agent, approvals)
      owner = Phronomy::Agent::ExecutionRegistry.existing_for(Phronomy::Runtime.instance)&.agent_execution_owner(request.execution_id)

      resolved = Phronomy::Agent::Base.live_for_execution(request.execution_id)

      expect(resolved).to be(agent)
      expect(resolved).to be(owner.agent)
    end

    it "returns the same live owner Agent through its concrete Agent class" do
      _original, request = invoke_and_suspend(agent, approvals)

      resolved = HITLAgentForApproveAsync.live_for_execution(request.execution_id)

      expect(resolved).to be(agent)
    end

    it "does not load Agent or Execution state from Persistence" do
      _original, request = invoke_and_suspend(agent, approvals)

      expect(persistence.executions).not_to receive(:load)
      expect(persistence.agents).not_to receive(:load)

      expect(HITLAgentForApproveAsync.live_for_execution(request.execution_id)).to be(agent)
    end

    it "raises ExecutionRehydrationRequiredError when no live owner exists" do
      expect do
        Phronomy::Agent::Base.live_for_execution("missing-execution")
      end.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    end

    it "raises ArgumentError when the live owner is not an instance of the receiver class" do
      _original, request = invoke_and_suspend(agent, approvals)

      other_class = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "other-class-agent", version: 1
        model "test-model"
        instructions "other"
      end

      expect do
        other_class.live_for_execution(request.execution_id)
      end.to raise_error(
        ArgumentError,
        /belongs to HITLAgentForApproveAsync/
      )
    end
  end
end
