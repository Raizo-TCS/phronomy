# frozen_string_literal: true

require "spec_helper"
require "digest"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Native parent terminal-result custody policy acceptance" do
  include_context "a native child requiring approval"
  let(:effects) { [] }
  let(:child_tool) do
    results = effects
    behavior = -> { @baseline_behavior&.call }
    Class.new(Phronomy::Tool::Base) do
      tool_name "child_recovery_action"
      description "Records the one child action"
      param :input, type: :string, desc: "Action input"
      on_error :raise
      define_method(:execute) do |input:|
        results << input
        behavior.call
        "child action completed"
      end
    end
  end
  let(:child_class) { IntegrationFactors.agent_class("base", tools: [child_tool]) }

  let(:parent_class) do
    worker, selected_policy = child_class, policy
    Class.new(Phronomy::MultiAgent::Orchestrator) do
      agent_definition id: "parent-result-policy-#{selected_policy}", version: 1
      model IntegrationFactors::LM_MODEL_30
      provider :openai
      tools IntegrationFactors::NoApprovalTool => nil
      subagent :worker, worker, on_error: selected_policy
    end
  end

  before do
    RubyLLM.configure do |configuration|
      configuration.openai_protocol = :chat_completions
      configuration.openai_api_key = "test"
    end
    responses = [dispatch, LLMStub.tool_call_response("child_recovery_action", {input: "once"})]
    responses << "child completed" if ending == :success
    responses << "parent completed"
    @recorder = LLMStub.activate(responses: responses)
    @runtime = Phronomy::Runtime.instance
    allow_any_instance_of(child_class).to receive(:start_reserved_async).and_wrap_original do |original, **options|
      @child_agent_id = original.receiver.agent_id
      @child_execution_id = options.fetch(:reservation).execution_id
      original.call(**options).tap { |task| @original_child_task ||= task }
    end
  end

  after { @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2) }

  def result_of(task) = task.wait_result(timeout: 8)

  [:raise, :skip].each do |selected_policy|
    [:success, :failure, :cancellation].each do |selected_ending|
      context "with #{selected_policy} policy and child #{selected_ending}" do
        let(:policy) { selected_policy }
        let(:ending) { selected_ending }
        it "preserves business semantics and records exact custody and release evidence" do
          @baseline_behavior = if ending == :failure
            -> { raise IOError, "ordinary child action failed" }
          elsif ending == :cancellation
            -> {
              stores.agent.request_cancellation(agent_id: @child_agent_id, execution_id: @child_execution_id)
              raise Phronomy::CancellationError, "ordinary child action cancelled"
            }
          end
          reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
          original = parent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
          expected_failure = ending == :cancellation || (ending == :failure && policy == :raise)
          parent_error = nil
          if expected_failure
            expect { result_of(original) }.to raise_error(Phronomy::Error) { |error| parent_error = error }
            expect(parent_error).not_to be_a(Phronomy::TimeoutError)
            expect(parent_error).not_to be_a(Phronomy::RuntimeShutdownError)
          else
            expect(result_of(original)).to include(output: "parent completed")
          end
          child = child_class.get(@child_agent_id)
          child_result = result_of(@original_child_task)
          expect(child_result.fetch(:status)).to eq({success: :completed, failure: :failed, cancellation: :cancelled}.fetch(ending))
          result = parent.resume(root_id)
          expect(result.fetch(:status)).to eq(expected_failure ? :failed : :completed)
          if expected_failure
            expected_message = (ending == :failure) ? "ordinary child action failed" : "ordinary child action cancelled"
            expect(parent_error.message).to include(expected_message)
            expect(result.fetch(:error).to_s).to include(expected_message)
          end
          extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
            binding_key: "phronomy.subagent")
          children = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children")
          expected_imported = !expected_failure
          expected_acknowledged = expected_failure
          expected_release = expected_imported || expected_acknowledged
          slot = children.fetch(0)
          expect(slot.fetch("imported")).to eq(expected_imported)
          if expected_acknowledged
            observed = stores.agent.observe_execution(agent_id: child.agent_id, execution_id: @child_execution_id)
            outcome = {"result" => observed.result, "raw_output" => observed.raw_output,
                       "error" => observed.error, "transfer_receipt" => observed.transfer_receipt}
            expect(slot.fetch("terminal_acknowledgement")).to eq(
              "version" => 1, "agent_id" => child.agent_id, "execution_id" => @child_execution_id,
              "reservation" => observed.reservation.correlation, "status" => observed.status.to_s,
              "outcome_digest" => Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(outcome))
            )
          else
            expect(slot).not_to have_key("terminal_acknowledgement")
          end
          registry = child.__execution_environment.registry
          expect(registry.agent_execution_admitted?(child.agent_id)).to be(false)
          expect(registry.agent_execution_admitted?(parent.agent_id)).to be(false)
          holds = [parent, child].to_h { |agent| [agent.agent_id, stores.agent.retained_references(agent_id: agent.agent_id).map(&:to_h)] }
          expect(holds.fetch(parent.agent_id)).to eq([Phronomy::Agent::Retention.new(agent_id: parent.agent_id,
            execution_id: root_id, owner_key: "subagent:#{root_id}").to_h])
          expect(holds.fetch(child.agent_id)).to eq([Phronomy::Agent::Retention.new(agent_id: child.agent_id,
            execution_id: @child_execution_id, owner_key: "subagent:#{root_id}").to_h])
          if expected_release
            expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
            expect(parent_class.get(parent.agent_id)).to be_nil
            expect(child_class.get(child.agent_id)).to be_nil
          else
            expect { parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id) }
              .to raise_error(Phronomy::AgentBusyError, "No matching completed coordination history")
          end
          holds.each do |id, before|
            expect(stores.agent.retained_references(agent_id: id).map(&:to_h)).to eq(before)
          end
          expected_calls = if ending == :success
            4
          else
            expected_failure ? 2 : 3
          end
          expect(@recorder.calls.size).to eq(expected_calls)
          expect(effects).to eq(["once"])
        end
      end
    end
  end
  context "when the parent terminal save loses its response" do
    let(:policy) { :raise }
    let(:ending) { :failure }

    def lose_parent_terminal_reply(mode:, unreadable: false)
      @parent_fault = {armed: true, readback: false, attempts: 0}
      allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
        change = original.receiver
        selected = change.agent_id == parent.agent_id && change.execution_id == root_id && change.kind == :terminal
        Thread.current[:parent_terminal_acknowledgement_fault] = selected
        original.call
      ensure
        Thread.current[:parent_terminal_acknowledgement_fault] = nil
      end
      allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
        selected = Thread.current[:parent_terminal_acknowledgement_fault]
        if selected && @parent_fault[:readback]
          @parent_fault[:readback] = false
          raise IOError, "parent immediate readback unavailable"
        end
        next original.call(*args, &transaction) unless selected && @parent_fault[:armed]
        @parent_fault[:armed] = false
        @parent_fault[:attempts] += 1
        if mode == :pre
          original.call(*args) do |scope|
            transaction.call(scope)
            @parent_fault[:readback] = unreadable
            raise IOError, "parent terminal transaction rolled back and response lost"
          end
        else
          original.call(*args, &transaction)
          @parent_fault[:readback] = unreadable
          raise IOError, "parent terminal transaction committed and response lost"
        end
      end
    end

    [:pre, :post].product([false, true]).each do |mode, unreadable|
      it "keeps acknowledgement atomic for #{mode} loss with readback #{unreadable ? "unavailable" : "available"}" do
        @baseline_behavior = -> { raise IOError, "ordinary child action failed" }
        lose_parent_terminal_reply(mode: mode, unreadable: unreadable)
        reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: root_id)
        original = parent.start_hosted(reservation: reservation, input: "run", config: {cancellation_token: token})
        error = nil
        expect { result_of(original) }.to raise_error { |failure| error = failure }
        expect(error).not_to be_a(Phronomy::TimeoutError)
        expect(@parent_fault[:attempts]).to eq(1)
        child = child_class.get(@child_agent_id)
        child_result = result_of(@original_child_task)
        expect(child_result.fetch(:status)).to eq(:failed)
        saved = stores.agent.executions.load(root_id)
        extension = stores.agent.execution_extension(agent_id: parent.agent_id, execution_id: root_id,
          binding_key: "phronomy.subagent")
        slot = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children").first
        expect(slot.fetch("imported")).to be(false)
        expect(saved.terminal?).to eq(mode == :post)
        if mode == :post
          expect(slot.fetch("terminal_acknowledgement")).to include("execution_id" => @child_execution_id,
            "status" => "failed")
        else
          expect(slot).not_to have_key("terminal_acknowledgement")
        end
        if mode == :post
          # The failed caller observation does not erase a committed receipt.
          # Unload makes its own fresh guarded proof after local work finishes.
          expect(error.message).to include("ordinary child action failed") unless unreadable
          expect(parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id)).to be(true)
        else
          expect { parent.unload_with_completed_child!(root_id, execution_id: @child_execution_id) }
            .to raise_error(Phronomy::AgentBusyError)
        end
        expect(stores.agent.retained_references(agent_id: parent.agent_id)).not_to be_empty
        expect(stores.agent.retained_references(agent_id: child.agent_id)).not_to be_empty
        expect(effects).to eq(["once"])
        expect(@recorder.calls.size).to eq(2)
        expect { result_of(original) }.to raise_error { |observed| expect(observed).to equal(error) }
        expect(parent.pending_terminal_recovery(execution_id: root_id)).to be_nil
        if unreadable
          expect(error).to be_a(Phronomy::ExecutionRehydrationRequiredError)
        elsif mode == :pre
          expect(error).to be_a(IOError)
        end
      end
    end
  end
end
