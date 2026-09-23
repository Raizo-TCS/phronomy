# frozen_string_literal: true

require "spec_helper"

RSpec.describe Phronomy::Agent::ExecutionOutcomeCommitter do
  let(:persistence) { Phronomy::Persistence.in_memory }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "outcome-contract", version: 1
    end
  end
  let(:agent) { agent_class.create(agent_id: "outcome-agent", persistence: persistence) }
  let(:worker) { described_class.new(agent: agent, persistence: persistence) }
  let(:metadata) { {} }
  let(:execution) do
    input = Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id,
      execution_id: "outcome-execution", kind: :external_message, channel: :llm, role: :user,
      content_ref: persistence.contents.put_text("input"),
      context_generation: agent.agent_root.transcript_generation, context_candidate: true)
    Phronomy::Agent::AgentExecution.start(agent_root: agent.agent_root,
      input_record: input, execution_id: "outcome-execution", metadata: metadata)
      .with(status: :active, phase: :calling_llm)
  end
  let(:view) do
    described_class::TerminalView.new(phase: :completed, output: "answer", usage: {input_tokens: 3},
      approval_request: nil, rejected: false, input_blocked: false, output_blocked: false,
      block_error: nil, invocation_error: nil, handoff: nil, callback_failure: nil,
      source_error: nil, cancel_requested: false)
  end

  let(:approval_request) do
    item = Phronomy::Agent::ToolApprovalRequest::Item.new(tool_invocation_id: "child-1",
      tool_call_id: "call-1", tool_name: "lookup", arguments: {}, facts: {},
      reason: "approval required", origin: :local, metadata: {})
    Phronomy::Agent::ToolApprovalRequest.new(execution_id: execution.execution_id, items: [item])
  end

  def command(**changes)
    described_class::Command.new(execution_id: execution.execution_id, fsm_session_id: "session-1",
      expected_execution_revision: execution.execution_revision, root: agent.agent_root,
      journal_records: [].freeze, execution: execution,
      runtime_snapshot: {llm_results: [].freeze, runtime_events: [].freeze, active_call: nil}.freeze,
      terminal_view: view, state_required: true, **changes)
  end

  def lose_response
    allow(persistence).to receive(:transaction).and_wrap_original do |original, &write|
      original.call(&write)
      raise IOError, "response lost after commit"
    end
  end

  before do
    persistence.transaction { |tx| tx.executions.create_active(execution) }
  end

  after { Phronomy.reset_runtime! }

  [false, true].each do |rejected|
    it "atomically saves completed output with rejected=#{rejected} without changing live state" do
      operation = command(terminal_view: view.with(rejected: rejected))
      result = worker.commit_outcome(operation)
      saved = persistence.executions.load(execution.execution_id)
      expect(saved.to_h).to eq(result.execution.to_h)
      expect(saved.status).to eq(rejected ? :rejected : :completed)
      expect(saved.execution_revision).to eq(execution.execution_revision + 1)
      expect(result.root.agent_revision).to eq(operation.root.agent_revision + 1)
      expect(result.root.context_revision).to eq(operation.root.context_revision + 1)
      expect(result.root.journal_position).to eq(operation.root.journal_position + 3)
      expect(result.appended_records.map(&:kind)).to eq([:external_message, :final_output,
        rejected ? :execution_rejected : :execution_completed])
      expect(result.result[:output]).to eq("answer")
      expect(result.result[:rejected]).to eq(rejected ? true : nil)
      expect(result.result[:usage]).to eq(view.usage)
      expect(result.result.fetch(:messages).map(&:content)).to eq(["input"])
      expect(agent.agent_root).to equal(operation.root)
      expect(operation.execution).to equal(execution)
    end
  end

  {Phronomy::Error => :failed, Phronomy::CancellationError => :cancelled,
   Phronomy::FilterBlockError => :blocked, Phronomy::TimeoutError => :failed}.each do |error_class, status|
    it "saves #{error_class} as #{status} with audit-only records" do
      error = error_class.new("execution failed")
      operation = command(terminal_view: view.with(source_error: error))
      result = worker.commit_outcome(operation)
      expect(result.type).to eq(:failed)
      expect(result.error).to equal(error)
      expect(result.execution.status).to eq(status)
      expect(result.root.context_revision).to eq(operation.root.context_revision)
      expect(result.appended_records.none?(&:context_candidate)).to be(true)
      expect(result.appended_records.last.kind).to eq(:"execution_#{status}")
      expect(persistence.contents.fetch_json(result.execution.error_ref)).to eq(
        "class" => error_class.name, "message" => error.message
      )
    end
  end

  it "retains approval records in nonterminal working state without advancing Journal or Context" do
    request = approval_request
    operation = command(terminal_view: view.with(phase: :suspended, approval_request: request))
    result = worker.commit_outcome(operation)
    expect(result.type).to eq(:suspended)
    expect(result.execution).not_to be_terminal
    expect(result.execution.phase).to eq(:approval)
    expect(result.execution.working_records.map(&:kind)).to eq(%i[external_message approval_required])
    expect(result.root.lifecycle_status).to eq(:suspended)
    expect(result.root.context_revision).to eq(operation.root.context_revision)
    expect(result.root.journal_position).to eq(operation.root.journal_position)
    expect(result.approval_request).to equal(request)
    expect(result.appended_records).to be_empty
  end

  [nil, Phronomy::CancellationError.new("cancelled")].each do |error|
    it "reuses a committed #{error ? "failed" : "completed"} result after F1 response loss without another write" do
      operation = command(terminal_view: view.with(source_error: error))
      lose_response
      result = worker.commit_outcome(operation)
      expect(result.type).to eq(error ? :failed : :completed)
      expect(result.execution.execution_revision).to eq(execution.execution_revision + 1)
      expect(persistence).to have_received(:transaction).once
      expect(result.root.to_h).to eq(persistence.agents.load(agent.agent_id).to_h)
      if error
        expect(result.error).to be_an_instance_of(Phronomy::Error)
        expect(result.error.message).to eq("Phronomy::CancellationError: cancelled")
      else
        expect(result.result[:output]).to eq("answer")
        # Readback retains the existing durable-result shape, not the live result shape.
        expect(result.result).not_to have_key(:messages)
      end
    end
  end

  it "does not adopt a suspended response loss as a terminal success (F1)" do
    request = approval_request
    operation = command(terminal_view: view.with(phase: :suspended, approval_request: request))
    lose_response
    expect { worker.commit_outcome(operation) }.to raise_error(IOError, /response lost/)
    expect(persistence).to have_received(:transaction).once
    expect(persistence.executions.load(execution.execution_id).status).to eq(:suspended)
  end

  it "rolls back a transcript failure and does not attempt a second terminal transition" do
    operation = command
    allow(Phronomy::Agent::RubyLLMMaterializer).to receive(:new).and_wrap_original do |original, **args|
      reader = original.call(**args)
      allow(reader).to receive(:materialize_journal_records).and_raise(IOError, "transcript unavailable")
      reader
    end
    allow(persistence).to receive(:transaction).and_call_original
    expect { worker.commit_outcome(operation) }.to raise_error(IOError, /transcript unavailable/)
    expect(persistence).to have_received(:transaction).once
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(operation.root.to_h)
    expect(persistence.journals.read(agent.agent_id, after: 0)).to be_empty
  end

  it "rolls back Execution and Journal if Root CAS loses (F2/G5/G8)" do
    operation = command
    concurrent = operation.root.with(agent_revision: operation.root.agent_revision + 1)
    persistence.agents.save(agent.agent_id, expected_revision: operation.root.agent_revision, root: concurrent)
    expect { worker.commit_outcome(operation) }.to raise_error(Phronomy::Storage::ConflictError)
    expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
    expect(persistence.journals.read(agent.agent_id, after: 0)).to be_empty
    expect(persistence.agents.load(agent.agent_id).to_h).to eq(concurrent.to_h)
  end

  it "propagates a readback failure without retrying an uncertain write (F1)" do
    operation = command
    lose_response
    allow(persistence.executions).to receive(:load).and_raise(IOError, "readback unavailable")
    expect { worker.commit_outcome(operation) }.to raise_error(IOError, /readback unavailable/)
    expect(persistence).to have_received(:transaction).once
  end

  [:active, :wrong_agent, :wrong_revision].each do |mismatch|
    it "does not adopt #{mismatch} as a confirmed terminal result (F1)" do
      operation = command
      confirmed = execution.with(status: :completed)
      confirmed = case mismatch
      when :active then execution
      when :wrong_agent then confirmed.with(agent_id: "other", execution_revision: confirmed.execution_revision)
      else confirmed.with(execution_revision: confirmed.execution_revision + 1)
      end
      allow(persistence).to receive(:transaction).and_raise(IOError, "unknown outcome")
      allow(persistence.executions).to receive(:load).and_return(confirmed)
      expect { worker.commit_outcome(operation) }.to raise_error(IOError, /unknown outcome/)
      expect(persistence).to have_received(:transaction).once
    end
  end

  it "uses terminal identity/revision rather than comparing a new intended payload (F1)" do
    operation = command
    committed = worker.commit_outcome(operation)
    allow(persistence).to receive(:transaction).and_raise(IOError, "response unavailable")
    result = worker.commit_outcome(operation.with(terminal_view: view.with(rejected: true)))
    expect(result.execution.to_h).to eq(committed.execution.to_h)
    expect(result.execution.status).to eq(:completed)
    expect(persistence).to have_received(:transaction).once
  end

  context "owned child coordination" do
    let(:child_state) { "active" }
    let(:metadata) do
      {"multi_agent_coordination_ref" => persistence.contents.put_json(
        "children" => [{"state" => child_state}]
      )}
    end

    it "retains an active child and cancellation intent in a nonterminal wait" do
      operation = command(terminal_view: view.with(cancel_requested: true))
      result = worker.commit_outcome(operation)
      expect(result.type).to eq(:coordination_wait)
      expect(result.execution.status).to eq(:active)
      expect(result.execution.metadata["coordination_cancel_requested"]).to be(true)
      expect(result.error).to be_a(Phronomy::ExecutionRehydrationRequiredError)
      expect(result.root).to equal(operation.root)
      expect(result.appended_records).to be_empty
    end

    it "adopts exactly the saved waiting record after response loss (F1)" do
      operation = command(terminal_view: view.with(cancel_requested: true))
      lose_response
      result = worker.commit_outcome(operation)
      expect(result.type).to eq(:coordination_wait)
      expect(result.execution.to_h).to eq(persistence.executions.load(execution.execution_id).to_h)
      expect(persistence).to have_received(:transaction).once
    end

    it "rejects a different waiting payload even at the expected revision (F1)" do
      operation = command(terminal_view: view.with(cancel_requested: true))
      lose_response
      allow(persistence.executions).to receive(:load).and_wrap_original do |original, id|
        saved = original.call(id)
        saved.with(metadata: saved.metadata.merge("different" => true), execution_revision: saved.execution_revision)
      end
      expect { worker.commit_outcome(operation) }.to raise_error(IOError, /response lost/)
      expect(persistence).to have_received(:transaction).once
    end

    context "a cancelled reservation" do
      let(:child_state) { "reserved" }

      it "does not wait for an unstarted cancelled child" do
        operation = command(terminal_view: view.with(cancel_requested: true,
          source_error: Phronomy::CancellationError.new("cancelled")))
        expect(worker.commit_outcome(operation).execution.status).to eq(:cancelled)
      end
    end
  end

  context "Handoff persistence" do
    let(:worker) { Phronomy::Agent::HandoffOutcomeCommitter.new(agent: agent, persistence: persistence) }
    let(:target) { agent_class.create(agent_id: "handoff-target", persistence: persistence) }
    let(:routing) do
      Phronomy::Agent::HandoffState.new(main_agent_id: agent.agent_id, handoff_revision: 1,
        active_agent_id: agent.agent_id, active_handoff_context_ref: nil, phase: "stable",
        pending_source_execution_id: nil, pending_target_execution_id: nil,
        created_at: Time.now.utc.iso8601(6), updated_at: Time.now.utc.iso8601(6), metadata: {})
    end
    let(:manifest) do
      Phronomy::Agent::LLMInputManifest.new(call_sequence: 1, call_mode: :complete, segments: [],
        model_config_ref: persistence.contents.put_json({}), assembly_policy_version: 7)
    end
    let(:metadata) do
      {"manifest_ref" => persistence.contents.put_json(manifest.to_h),
       "coordination" => {"kind" => "handoff", "main_agent_id" => agent.agent_id,
                          "handoff_revision" => routing.handoff_revision}}
    end
    let(:request) do
      described_class::HandoffTerminalView.new(target_agent_id: target.agent_id, responsibility: "Continue",
        selection_intent: {}.freeze, llm_call_id: "call-1", tool_call_id: "tool-1",
        policy: Phronomy::Values::Immutable.copy(Phronomy::Agent::HandoffPolicy.default.to_h))
    end
    let(:view) { super().with(handoff: request) }

    before { persistence.handoff_states.save(agent.agent_id, expected_revision: nil, state: routing) }

    it "atomically transfers routing, Context and Source to one deterministic Target ID" do
      operation = command
      result = worker.commit_outcome(operation)
      transfer = persistence.handoff_states.load(agent.agent_id)
      target_id = "handoff-target-#{Digest::SHA256.hexdigest([execution.execution_id, target.agent_id].join("\0"))}"
      expect(result.type).to eq(:handed_off)
      expect(result.execution.status).to eq(:handed_off)
      expect(result.execution.metadata["handoff_target_execution_id"]).to eq(target_id)
      expect(transfer.pending_target_execution_id).to eq(target_id)
      expect(transfer.phase).to eq("target_pending")
      expect(transfer.active_agent_id).to eq(target.agent_id)
      expect(transfer.metadata["target_definition"]).to eq("id" => "outcome-contract", "version" => 1)
      expect(result.appended_records.map(&:kind)).to eq(%i[external_message execution_handed_off])
      expect(result.root.context_revision).to eq(operation.root.context_revision + 1)
      expect(persistence.contents.fetch_json(transfer.active_handoff_context_ref)["responsibility"]).to eq("Continue")
      expect { persistence.executions.load(target_id) }.to raise_error(Phronomy::Storage::NotFoundError)
      expect(agent.agent_root).to equal(operation.root)
    end

    it "reuses Source transfer after F1 without rebuilding Context or advancing routing twice" do
      operation = command
      lose_response
      allow(Phronomy::Agent::HandoffProjection).to receive(:new).and_call_original
      result = worker.commit_outcome(operation)
      expect(result.type).to eq(:handed_off)
      expect(Phronomy::Agent::HandoffProjection).to have_received(:new).once
      expect(persistence).to have_received(:transaction).once
      expect(persistence.handoff_states.load(agent.agent_id).handoff_revision).to eq(2)
    end

    it "rolls back transfer and Source when the Root save fails" do
      operation = command
      allow_any_instance_of(Phronomy::Agent::Persistence::AgentRepository).to receive(:save).and_raise(Phronomy::Storage::ConflictError, "Root conflict")
      expect { worker.commit_outcome(operation) }.to raise_error(Phronomy::Storage::ConflictError)
      expect(persistence.handoff_states.load(agent.agent_id).to_h).to eq(routing.to_h)
      expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
      expect(persistence.journals.read(agent.agent_id, after: 0)).to be_empty
    end

    [:owner, :revision, :cancelled].each do |conflict|
      it "rejects #{conflict} routing before transferring Source" do
        operation = command
        newer = case conflict
        when :owner then routing.with(active_agent_id: target.agent_id)
        when :cancelled then routing.with(metadata: {"cancelled_execution_ids" => [execution.execution_id]})
        else routing.with
        end
        persistence.handoff_states.save(agent.agent_id, expected_revision: 1, state: newer)
        if conflict == :cancelled
          current = Phronomy::Agent::ExecutionMetadata.with_values(execution,
            "coordination" => metadata.fetch("coordination").merge("handoff_revision" => 2))
          operation = operation.with(execution: current)
        end
        error_class = (conflict == :cancelled) ? Phronomy::CancellationError : Phronomy::Storage::ConflictError
        expect { worker.commit_outcome(operation) }.to raise_error(error_class)
        expect(persistence.handoff_states.load(agent.agent_id).to_h).to eq(newer.to_h)
        expect(persistence.executions.load(execution.execution_id).to_h).to eq(execution.to_h)
      end
    end

    [nil, Phronomy::Error.new("Target failed")].each do |error|
      it "stabilizes Target routing in the same #{error ? "failure" : "completion"} transaction" do
        operation = command(terminal_view: view.with(handoff: nil, source_error: error))
        pending = routing.with(phase: "target_active", pending_target_execution_id: execution.execution_id)
        persistence.handoff_states.save(agent.agent_id, expected_revision: 1, state: pending)
        result = worker.commit_outcome(operation)
        expect(result.type).to eq(error ? :failed : :completed)
        expect(persistence.handoff_states.load(agent.agent_id).phase).to eq("stable")
      end
    end

    it "does not acquire ordinary child-wait selection for a Handoff recovery error" do
      operation = command
      reference = persistence.contents.put_json("children" => [{"state" => "active"}])
      current = Phronomy::Agent::ExecutionMetadata.with_values(execution,
        "multi_agent_coordination_ref" => reference)
      operation = operation.with(execution: current,
        terminal_view: view.with(source_error: Phronomy::ExecutionRehydrationRequiredError.new("recover")))
      expect(persistence).not_to receive(:transaction)
      expect { worker.commit_outcome(operation) }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
    end

    it "preserves callback precedence over Source error, suspension and Handoff" do
      failure = Phronomy::StreamCallbackError.new(event_type: :text_delta, original_error: RuntimeError.new("callback"))
      callback = double(to_stream_callback_error: failure)
      operation = command(terminal_view: view.with(callback_failure: callback, phase: :suspended,
        source_error: Phronomy::ExecutionRehydrationRequiredError.new("recover")))
      expect(worker.commit_outcome(operation).error).to equal(failure)
      expect(persistence.handoff_states.load(agent.agent_id).to_h).to eq(routing.to_h)
    end
  end

  it "retains internal type paths and members while moving their canonical ownership" do
    {HandoffTerminalView: :HandoffTerminalView, TerminalView: :TerminalView,
     TerminalCommitCommand: :Command, TerminalOutcome: :Outcome}.each do |old_name, new_name|
      expect(Phronomy::Agent::ExecutionCoordinator.const_get(old_name)).to equal(described_class.const_get(new_name))
      expect(described_class.const_get(new_name).name).to eq("#{described_class.name}::#{new_name}")
    end
    expect(described_class::Command.members).to eq(%i[execution_id fsm_session_id expected_execution_revision
      root journal_records execution runtime_snapshot terminal_view state_required])
    expect(described_class::Outcome.members).to eq(%i[type execution root appended_records result error approval_request])
  end
end
