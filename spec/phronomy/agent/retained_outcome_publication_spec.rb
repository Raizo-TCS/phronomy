# frozen_string_literal: true

require "spec_helper"
require_relative "../../integration/support/hosted_subagent"

RSpec.describe "Captured outcome publication through the original Runtime" do
  include_context "a native child requiring approval"

  before do
    @runtime = Phronomy::Runtime.instance
    @counts = Hash.new(0)
    @gates = []
  end

  after do
    @gates.each { |waiting| waiting.fetch(:release) << true }
    @runtime.shutdown(timeout: 0.03, cancel_grace: 0.2)
  end

  def result_of(task) = task.wait_result(timeout: 8)
  def take(queue) = Timeout.timeout(8) { queue.pop }

  def setup_publication(kind:, mode:, response: "captured answer", error: nil, &after_capture)
    @kind = kind
    @agent = if kind == :native
      parent
    else
      Class.new(Phronomy::Agent::Base) do
        agent_definition id: "retained-publication", version: 1
        tools IntegrationFactors::NoApprovalTool => nil
      end.create(persistence: stores.agent)
    end
    counts = @counts
    replies = [Phronomy::LLMAdapter::Response.new(finish_reason: :tool_calls, tool_calls: [
      Phronomy::Tool::CallRequest.new(id: "publication-call", name: "no_approval_tool", arguments: {value: "once"})
    ]), error || Phronomy::LLMAdapter::Response.new(content: response, finish_reason: :stop)]
    adapter = Class.new(Phronomy::LLMAdapter::Base) do
      define_method(:perform_complete) do |_request, cancellation_token:|
        cancellation_token&.raise_if_cancelled!
        counts[:provider] += 1
        reply = replies.shift
        raise reply if reply.is_a?(Exception)
        reply || raise("Provider execution repeated after captured outcome")
      end
    end.new
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
    allow_any_instance_of(IntegrationFactors::NoApprovalTool).to receive(:execute).and_wrap_original do |original, **options|
      @counts[:tool] += 1
      original.call(**options)
    end
    allow(Phronomy::Agent::RuntimeRecordEncoder).to receive(:encode).and_wrap_original do |original, *args, **options|
      @counts[:encoder] += 1
      original.call(*args, **options)
    end
    allow_any_instance_of(Phronomy::Agent::OutcomeRecoveryOperation).to receive(:capture_evidence).and_wrap_original do |original, proof|
      original.call(proof)
      @recovery = original.receiver.recovery
      @captured_counts = @counts.dup
      after_capture&.call
    end
    install_publication_fault(mode)
  end

  # Use the same real transaction and immediate-readback fault boundaries as
  # the native parent recovery acceptance specs; no domain outcome is replaced.
  def install_publication_fault(mode)
    armed = mode != :none
    readback = false
    allow_any_instance_of(Phronomy::Agent::ExecutionChange).to receive(:perform).and_wrap_original do |original|
      change = original.receiver
      Thread.current[:retained_publication_save] = change.execution_id == root_id && change.kind == :terminal
      original.call
    ensure
      Thread.current[:retained_publication_save] = nil
    end
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      selected = Thread.current[:retained_publication_save]
      if selected && readback
        readback = false
        raise IOError, "immediate publication readback unavailable"
      end
      next original.call(*args, &transaction) unless selected && armed
      armed = false
      if mode == :pre
        original.call(*args) do |scope|
          transaction.call(scope)
          readback = true
          raise IOError, "complete captured save rolled back"
        end
      else
        original.call(*args, &transaction)
        readback = true
        raise IOError, "captured save committed but response lost"
      end
    end
  end

  def start_publication(**options)
    reservation = Phronomy::Agent::ReservedExecution.new(agent_id: @agent.agent_id, execution_id: root_id)
    @original = @agent.start_hosted(reservation: reservation, input: "run once", **options)
  end

  def recover_publication(mode)
    expected = (@kind == :native) ? Phronomy::Agent::OutcomeRecoveryError : Phronomy::Agent::TerminalRecoveryError
    expect { result_of(@original) }.to raise_error(expected) { |error| @closed_error = error }
    expect(@closed_error.recovery).to equal(@recovery)
    receipt = observe_publication(:reconcile)
    if mode == :pre
      expect(receipt.outcome).to eq(:confirmed_pre)
      expect(receipt.ownership_state).to eq(:retained)
      expect(receipt.execution).to be_nil
      receipt = observe_publication(:retry)
    end
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@closed_error) }
    receipt
  end

  def observe_publication(action, async: false)
    suffix = (@kind == :native) ? "outcome" : "terminal"
    @agent.public_send("#{action}_#{suffix}#{"_async" if async}", recovery: @recovery)
  end

  def saved_observation
    stores.agent.observe_execution(agent_id: @agent.agent_id, execution_id: root_id)
  end

  def expect_stable_publication(receipt, status:)
    expect(receipt.outcome).to eq(:confirmed_post)
    expect(receipt.application_state).to eq(:applied)
    expect(receipt.ownership_state).to eq(:released)
    expect(receipt.execution.status).to eq(status)
    expect(receipt.execution).to eq(saved_observation)
    expect(@counts).to eq(@captured_counts)
    expect(@counts).to include(provider: 2, tool: 1)
    expect(@counts.fetch(:encoder)).to be_positive
    2.times { expect(observe_publication(:reconcile).execution).to eq(receipt.execution) }
    expect(@agent.unload!).to be(true)
  end

  %i[native standalone].each do |kind|
    %i[none pre post].each do |mode|
      it "publishes captured text for #{kind} after #{mode} save loss despite mutable application output" do
        output = +"captured answer"
        setup_publication(kind: kind, mode: mode) { output.replace("changed after capture") }
        @agent.add_output_filter(->(_text) { output })
        start_publication
        receipt = if mode == :none
          result = result_of(@original)
          expect(result.fetch(:output)).to equal(output)
          observe_publication(:reconcile)
        else
          recover_publication(mode)
        end
        expect(output).to eq("changed after capture")
        expect(output).not_to be_frozen
        expect(receipt.execution.result).to eq("captured answer")
        output.replace("changed after publication")
        expect_stable_publication(receipt, status: :completed)
      end

      it "publishes a saved #{kind} failure after #{mode} loss without reopening its exception diagnostic" do
        sealed = false
        reads = 0
        captured_reads = nil
        failure = Class.new(IOError) do
          define_method(:message) do
            reads += 1
            raise IOError, "business diagnostic unavailable after capture" if sealed
            "original business failure"
          end
        end.new
        setup_publication(kind: kind, mode: mode, error: failure) do
          captured_reads = reads
          sealed = true
        end
        start_publication
        receipt = if mode == :none
          observed = begin
            result_of(@original)
          rescue => error
            error
          end
          expect(observed).to equal(failure)
          observe_publication(:reconcile)
        else
          recover_publication(mode)
        end
        expect(receipt.execution).to be_a(Phronomy::Agent::ExecutionObservation)
        expect(receipt.execution.error.fetch("message")).to eq("original business failure")
        expect(receipt.execution.result).to be_nil
        expect_stable_publication(receipt, status: :failed)
        expect(reads).to eq(captured_reads)
      end
    end

    it "preserves structured result and raw output for #{kind} after a lost commit response" do
      raw = +'{"answer":"captured answer"}'
      setup_publication(kind: kind, mode: :post, response: raw) { raw.replace("changed caller input") }
      schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
      start_publication(output_schema: schema)
      receipt = recover_publication(:post)
      expect(receipt.execution.result).to eq("answer" => "captured answer")
      expect(receipt.execution.raw_output).to eq('{"answer":"captured answer"}')
      expect(raw).to eq("changed caller input")
      expect_stable_publication(receipt, status: :completed)
    end

    it "preserves the complete #{kind} OutputError diagnostic and its restored type" do
      raw = '{"answer":12}'
      setup_publication(kind: kind, mode: :pre, response: raw)
      schema = {type: "object", properties: {answer: {type: "string"}}, required: ["answer"], additionalProperties: false}
      start_publication(output_schema: schema)
      receipt = recover_publication(:pre)
      diagnostic = receipt.execution.error
      expect(diagnostic).to include("execution_id" => root_id, "reason" => "schema_mismatch", "raw_output" => raw,
        "code" => "agent.output_invalid")
      expect(diagnostic.fetch("schema_digest")).not_to be_empty
      expect(diagnostic.fetch("violations")).not_to be_empty
      expect { receipt.execution.value! }.to raise_error(Phronomy::Agent::OutputError) do |error|
        expect(error.execution_id).to eq(root_id)
        expect(error.schema_digest).to eq(diagnostic.fetch("schema_digest"))
        expect(error.violations).to eq(diagnostic.fetch("violations"))
        expect(error.raw_output).to eq(raw)
      end
      expect_stable_publication(receipt, status: :failed)
    end
  end

  it "coalesces native observers and keeps their published values stable after one caller cancels" do
    output = +"captured answer"
    setup_publication(kind: :native, mode: :post) { output.replace("changed after capture") }
    @agent.add_output_filter(->(_text) { output })
    start_publication
    expect { result_of(@original) }.to raise_error(Phronomy::Agent::OutcomeRecoveryError) { |error| @closed_error = error }
    waiting = {entered: Queue.new, release: Queue.new}
    @gates << waiting
    reads = 0
    allow(stores.agent.coordinator).to receive(:atomic).and_wrap_original do |original, *args, &transaction|
      reads += 1
      waiting.fetch(:entered) << true
      waiting.fetch(:release).pop
      original.call(*args, &transaction)
    end
    first = observe_publication(:reconcile, async: true)
    take(waiting.fetch(:entered))
    second = observe_publication(:reconcile, async: true)
    first.cancel!
    waiting.fetch(:release) << true
    receipt = result_of(second)
    expect(reads).to eq(1)
    expect { result_of(first) }.to raise_error(Phronomy::CancellationError)
    allow(stores.agent.coordinator).to receive(:atomic).and_call_original
    expect(receipt.execution.result).to eq("captured answer")
    expect { result_of(@original) }.to raise_error { |error| expect(error).to equal(@closed_error) }
    expect_stable_publication(receipt, status: :completed)
  end
end
