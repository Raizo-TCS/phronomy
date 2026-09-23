# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Execution owner result application (F0/F1/F3; no X0)" do
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "result-application-owner", version: 1
      model "local-model"
    end
  end
  let(:events) { [] }
  let(:agent) do
    agent_class.new(agent_id: "result-owner", persistence: Phronomy::Persistence.in_memory,
      on_event: ->(event) { events << [event.type, event.payload, observation] })
  end
  let(:coordinator) { agent.send(:execution_coordinator) }
  let(:runtime) { Phronomy::Runtime.instance }
  let(:registry) { Phronomy::Agent::ExecutionRegistry.for(runtime.event_loop) }
  let(:root) { agent.agent_root }
  let(:record) do
    Phronomy::Agent::JournalRecord.new(agent_id: agent.agent_id, execution_id: "execution-1",
      kind: :user_message, channel: :llm, role: :user,
      content_ref: agent.persistence.contents.put_text("input"),
      context_generation: root.transcript_generation, context_candidate: true)
  end
  let(:preparing) do
    Phronomy::Agent::AgentExecution.start(agent_root: root, input_record: record, execution_id: "execution-1")
  end
  let(:execution) { preparing.with(status: :active) }
  let(:result_task) { Phronomy::TaskResult.deferred(name: "result-observer") }
  let(:other_task) { Phronomy::TaskResult.deferred(name: "second-observer") }
  let(:exact_task) { Phronomy::TaskResult.deferred(name: "exact-observer") }
  let(:load_task) { Phronomy::TaskResult.deferred(name: "load-observer") }
  let(:invocation) do
    Phronomy::Agent::AgentInvocation.new(agent: agent, input: "input", execution_id: execution.execution_id,
      config: {execution_id: execution.execution_id, phronomy_exact_observers: [exact_task]})
  end
  let(:next_root) { root.with(agent_revision: root.agent_revision + 1, journal_position: 1) }
  let(:saved_record) { record.with_sequence(1) }

  def on_loop(&action)
    completion = Phronomy::TaskResult.deferred(name: "result-application-loop")
    handler = Object.new
    handler.define_singleton_method(:deliver_on_event_loop) do |_command|
      completion.complete(action.call)
    rescue => error
      completion.fail(error)
    end
    registry.post(Struct.new(:coordinator).new(handler), completion: completion)
    completion.wait_result(timeout: 3)
  end

  def install(**changes)
    on_loop do
      token = Object.new
      registry.admit_agent_execution(agent.agent_id, owner_token: token)
      registry.bind_agent_execution_admission(agent.agent_id, owner_token: token, execution_id: execution.execution_id)
      registry.install_agent_execution(execution_id: execution.execution_id, agent: agent,
        coordinator: coordinator, execution: execution, runtime_projection: nil, base_manifest: nil,
        invocation: invocation, fsm_session_id: "session-1", **changes)
      registry.register_agent_completion_waiter(execution.execution_id, result_task)
      registry.register_agent_completion_waiter(execution.execution_id, other_task)
    end
  end

  # Capture during delivery; assertions outside callbacks cannot be swallowed.
  def observation
    {root: agent.agent_root, records: agent.send(:_journal_records_snapshot),
     state: registry.agent_execution_state(execution.execution_id),
     admitted: registry.agent_execution_admitted?(agent.agent_id),
     tasks_done: [result_task.done?, other_task.done?], load_done: load_task.done?,
     runtime_events: invocation.runtime_snapshot.fetch(:runtime_events)}
  end

  def apply(ready)
    on_loop { coordinator.deliver_on_event_loop(ready) }
  end

  def hold_terminal_worker
    submitted = []
    allow(runtime.offload).to receive(:submit) do |**_, &work|
      submitted << work
      Phronomy::TaskResult.deferred(name: "held-terminal-worker")
    end
    allow(coordinator.instance_variable_get(:@outcome_committer)).to receive(:commit_outcome) { |operation| operation }
    submitted
  end

  after do
    on_loop do
      registry.release_agent_execution(execution.execution_id)
      registry.release_agent_execution_admission(agent.agent_id, execution_id: execution.execution_id)
      registry.take_agent_completion_waiters(execution.execution_id)
    end
  end

  describe "terminal results" do
    let(:operation) do
      invocation.send(:deliver_event, Phronomy::Agent::StreamEvent.new(type: :diagnostic, payload: {}))
      Phronomy::Agent::ExecutionCoordinator::TerminalCommitCommand.new(
        execution_id: execution.execution_id, fsm_session_id: "session-1",
        expected_execution_revision: execution.execution_revision, root: root,
        journal_records: [], execution: execution, runtime_snapshot: invocation.runtime_snapshot,
        terminal_view: nil, state_required: true
      )
    end
    let(:handoff_request) { Object.new }
    let(:handoff_manifest) { Object.new }
    let(:delivery) do
      Phronomy::Agent::ExecutionCoordinator::TerminalDelivery.new(result_task: result_task,
        application_listener: agent.send(:_phronomy_event_listener), approval_listener: nil,
        handoff_request: handoff_request, handoff_manifest: handoff_manifest)
    end

    def terminal_ready(type = :completed, error: nil, commit_error: nil, **changes)
      outcome = Phronomy::Agent::ExecutionCoordinator::TerminalOutcome.new(
        type: type, execution: execution.with(status: {coordination_wait: :active}.fetch(type, type)),
        root: next_root, appended_records: [saved_record],
        result: {execution_id: execution.execution_id, output: "done"},
        error: error, approval_request: {"id" => "approval-1"}
      )
      Phronomy::Agent::ExecutionCoordinator::TerminalCommitReady.new(coordinator: coordinator,
        operation: operation, delivery: delivery, outcome: outcome, error: commit_error, **changes)
    end

    [:missing, :other_agent, :revision, :session].each do |mismatch|
      [false, true].each do |failed|
        it "ignores #{mismatch} authority before #{failed ? "error handling" : "state application"} (F3)" do
          changes = case mismatch
          when :other_agent then {agent: Object.new}
          when :revision then {execution: execution.with(phase: :newer)}
          when :session then {fsm_session_id: "new-session"}
          else {}
          end
          install(**changes)
          on_loop { registry.release_agent_execution(execution.execution_id) } if mismatch == :missing
          ready = terminal_ready(commit_error: failed ? IOError.new("response lost") : nil)
          before = on_loop { observation }
          apply(ready)
          expect(on_loop { observation }).to eq(before)
          expect(events).to be_empty
          expect(on_loop { registry.take_agent_completion_waiters(execution.execution_id) }).to eq([result_task, other_task])
        end
      end
    end

    [:completed, :handed_off, :failed].each do |type|
      it "applies #{type} state and releases ownership before delivery and observer settlement" do
        install
        error = (type == :failed) ? Phronomy::Error.new("execution failed") : nil
        ready = terminal_ready(type, error: error)
        expect(agent.persistence).not_to receive(:transaction)
        apply(ready)
        event_type, payload, observed = events.fetch(0)
        expect(events.size).to eq(1)
        expect(observed).to include(root: next_root, records: [saved_record], state: nil,
          admitted: false, tasks_done: [false, false], runtime_events: [])
        expect(event_type).to eq({completed: :done, handed_off: :handoff, failed: :error}.fetch(type))
        if error
          expect(payload[:error]).to equal(error)
          [result_task, other_task].each { |task| expect { task.wait_result }.to raise_error(error) }
        else
          [result_task, other_task].each { |task| expect(task.wait_result).to eq(payload) }
          if type == :handed_off
            expect(payload[:handoff_request]).to equal(handoff_request)
            expect(payload[:_phronomy_handoff_manifest]).to equal(handoff_manifest)
            expect(ready.outcome.result).not_to have_key(:handoff_request)
          end
        end
      end
    end

    [Phronomy::CancellationError, Phronomy::TimeoutError].each do |error_class|
      it "retains #{error_class} precedence when the listener also fails" do
        install
        error = error_class.new("execution stopped")
        allow(Phronomy.configuration).to receive(:stream_callback_error_policy).and_return(:fail_task)
        ready = terminal_ready(:failed, error: error,
          delivery: delivery.with(application_listener: ->(_) { raise "callback failed" }))
        expect(agent.persistence).not_to receive(:transaction)
        apply(ready)
        [result_task, other_task].each { |task| expect { task.wait_result }.to raise_error(error) }
        expect(result_task.status).to eq((error_class == Phronomy::CancellationError) ? :cancelled : :failed)
      end
    end

    it "retains suspension and pending execution tasks while failing exact observers" do
      install
      allow(Phronomy.configuration).to receive(:stream_callback_error_policy).and_return(:fail_task)
      listener = ->(event) {
        events << [event.type, event.payload, observation]
        raise "approval callback failed"
      }
      approval_calls = Queue.new
      ready = terminal_ready(:suspended, delivery: delivery.with(application_listener: listener,
        approval_listener: ->(request) { approval_calls << [request, runtime.event_loop.current?] }))
      apply(ready)
      type, payload, observed = events.fetch(0)
      expect(type).to eq(:approval_required)
      expect(payload).to eq(request: ready.outcome.approval_request)
      expect(observed).to include(root: next_root, admitted: true, tasks_done: [false, false], runtime_events: [])
      expect(observed[:state].execution).to equal(ready.outcome.execution)
      expect(observed[:state].fsm_session_id).to be_nil
      expect(Timeout.timeout(3) { approval_calls.pop }).to eq([ready.outcome.approval_request, false])
      expect(result_task).not_to be_done
      expect(other_task).not_to be_done
      expect { exact_task.wait_result }.to raise_error(Phronomy::ExecutionRehydrationRequiredError)
      expect(on_loop { registry.take_agent_completion_waiters(execution.execution_id) }).to eq([result_task, other_task])
    end

    it "releases coordination waiting without publishing a terminal event" do
      install
      error = Phronomy::ExecutionRehydrationRequiredError.new("children remain")
      apply(terminal_ready(:coordination_wait, error: error))
      expect(events).to be_empty
      expect(on_loop { observation }).to include(root: next_root, state: nil, admitted: false, runtime_events: [])
      [result_task, other_task].each { |task| expect { task.wait_result }.to raise_error(error) }
    end

    it "leaves ordinary uncertain outcomes and observers pending for recovery (F1)" do
      install
      ready = terminal_ready(commit_error: IOError.new("response lost"))
      before = on_loop { observation }
      allow(registry).to receive(:mark_agent_execution_admission).and_call_original
      apply(ready)
      expect(on_loop { observation }).to eq(before)
      expect(events).to be_empty
      expect(registry).to have_received(:mark_agent_execution_admission)
        .with(agent.agent_id, execution_id: execution.execution_id, state: :recovery_required)
      expect(on_loop { registry.take_agent_completion_waiters(execution.execution_id) }).to eq([result_task, other_task])
    end

    ["coordination", "multi_agent_coordination_ref"].each do |key|
      it "releases a worker error carrying #{key} and fails all observers (F1)" do
        install
        error = IOError.new("coordination response lost")
        ready = terminal_ready(commit_error: error,
          operation: operation.with(execution: execution.with(metadata: {key => "saved-coordination"})))
        apply(ready)
        expect(events).to be_empty
        expect(on_loop { observation }).to include(root: root, records: [], state: nil, admitted: false)
        [result_task, other_task].each { |task| expect { task.wait_result }.to raise_error(error) }
      end
    end

    it "settles a pre-session terminal operation through its fallback observer" do
      install
      on_loop do
        registry.release_agent_execution(execution.execution_id)
        registry.take_agent_completion_waiters(execution.execution_id)
      end
      ready = terminal_ready(operation: operation.with(state_required: false, fsm_session_id: nil))
      apply(ready)
      expect(result_task.wait_result).to eq(ready.outcome.result)
      expect(other_task).not_to be_done
      expect(events.fetch(0).last).to include(state: nil, admitted: false, tasks_done: [false, false])
    end
  end

  describe "initial preparation recovery results" do
    let(:execution) { preparing }

    def recovery_ready(outcome = :terminal, error: Phronomy::Error.new("preparation failed"), commit_error: nil)
      result = Phronomy::Agent::InitialPreparation::Result.new(
        admission_outcome: outcome, execution: execution.with(status: (outcome == :active) ? :active : :failed),
        root: next_root, appended_records: [saved_record], config: {}, filtered_input: "filtered",
        runtime_projection: double("projection", manifest: nil), error: error
      )
      Phronomy::Agent::ExecutionCoordinator::InitialPreparationRecoveryReady.new(coordinator: coordinator,
        execution_id: execution.execution_id, expected_execution_revision: execution.execution_revision,
        result_task: result_task, load_completion: load_task, result: result, error: commit_error)
    end

    [:missing, :other_agent, :revision, :status, :phase].each do |mismatch|
      it "rejects #{mismatch} recovery authority without releasing the current owner (F3)" do
        changes = case mismatch
        when :other_agent then {agent: Object.new}
        when :revision then {execution: execution.with(phase: :preparing)}
        when :status then {execution: execution.with(status: :active, execution_revision: execution.execution_revision)}
        when :phase then {execution: execution.with(phase: :another, execution_revision: execution.execution_revision)}
        else {}
        end
        install(**changes)
        on_loop { registry.release_agent_execution(execution.execution_id) } if mismatch == :missing
        before = on_loop { observation }
        apply(recovery_ready(commit_error: IOError.new("late failure")))
        observed = on_loop { observation }
        expect(observed.slice(:root, :records, :state, :admitted)).to eq(before.slice(:root, :records, :state, :admitted))
        expect(events).to be_empty
        [result_task, load_task].each do |task|
          expect { task.wait_result }.to raise_error(Phronomy::ExecutionRehydrationRequiredError, /stale/)
        end
        expect(other_task).not_to be_done
      end
    end

    it "delivers recovered failure before execution settlement and successful load completion" do
      install
      ready = recovery_ready
      apply(ready)
      expect(events.fetch(0).last).to include(root: next_root, records: [saved_record], state: nil,
        admitted: false, tasks_done: [false, false], load_done: false)
      expect { result_task.wait_result }.to raise_error(ready.result.error)
      expect(load_task.wait_result).to equal(agent)
      expect(other_task).not_to be_done
    end

    [:worker, :unexpected, :apply].each do |failure|
      it "releases recovery ownership and fails both observers on #{failure} failure" do
        install
        ready = recovery_ready((failure == :unexpected) ? :outcome_unknown : :terminal,
          commit_error: (failure == :worker) ? IOError.new("worker failed") : nil)
        allow(agent).to receive(:__replace_root).and_raise(IOError, "apply failed") if failure == :apply
        apply(ready)
        expected_class = (failure == :unexpected) ? Phronomy::ExecutionRehydrationRequiredError : IOError
        expected_message = {worker: /worker failed/, unexpected: /unexpected initial preparation/, apply: /apply failed/}.fetch(failure)
        [result_task, load_task].each do |task|
          expect { task.wait_result }.to raise_error(expected_class, expected_message)
        end
        expect(on_loop { observation }).to include(state: nil, admitted: false)
        expect(events).to be_empty
      end
    end

    it "installs a recovered session before successful load completion" do
      install(fsm_session_id: nil)
      ready = recovery_ready(:active, error: nil)
      session = double("recovered session", id: "recovered-session", context: invocation)
      allow(Phronomy::Agent::AgentInvocationSessionBuilder).to receive(:build).and_return(session)
      runner = instance_double(Phronomy::Agent::ExecutionSessionRunner)
      registered = []
      allow(Phronomy::Agent::ExecutionSessionRunner).to receive(:new).and_return(runner)
      allow(runner).to receive(:register) { |*args| registered << [args, observation] }
      apply(ready)
      args, observed = registered.fetch(0)
      expect(args).to eq([session, result_task])
      expect(observed).to include(root: next_root, records: [saved_record], admitted: true, load_done: false)
      expect(observed[:state].execution).to equal(ready.result.execution)
      expect(observed[:state].fsm_session_id).to eq("recovered-session")
      expect(load_task.wait_result).to equal(agent)
      expect(result_task).not_to be_done
      expect(events).to be_empty
    end

    it "terminalizes registration failure while completing the load observer" do
      install(fsm_session_id: nil)
      submitted = hold_terminal_worker
      allow(Phronomy::Agent::AgentInvocationSessionBuilder).to receive(:build).and_raise(IOError, "registration failed")
      ready = recovery_ready(:active, error: nil)
      apply(ready)
      expect(load_task.wait_result).to equal(agent)
      expect(result_task).not_to be_done
      operation = submitted.fetch(0).call
      expect(operation.execution).to equal(ready.result.execution)
      expect(operation.state_required).to be false
      expect(operation.terminal_view.source_error.message).to eq("registration failed")
      expect(on_loop { observation }).to include(root: next_root, state: nil, admitted: true)
    end
  end

  describe "approval resume results" do
    let(:execution) { preparing.with(status: :active).with(status: :suspended, approval_request: {"id" => "approval-1"}) }
    let(:resume_task) { Phronomy::TaskResult.deferred(name: "resume-observer") }
    let(:ready) do
      request = Phronomy::Agent::ExecutionCoordinator::ResumeCommand.new(coordinator: coordinator,
        execution_id: execution.execution_id, approval_request_id: "approval-1", approved: true,
        config: {caller: "resume"}, result_task: resume_task)
      operation = Phronomy::Agent::ApprovalResumeCommit::Command.new(
        execution_id: execution.execution_id, expected_execution_revision: execution.execution_revision,
        root: root, execution: execution, approval_request_id: "approval-1", approved: true, tool_batch_snapshot: []
      )
      result = Phronomy::Agent::ApprovalResumeCommit::Result.new(execution: execution.with(status: :active), root: next_root)
      Phronomy::Agent::ExecutionCoordinator::ResumeCommitReady.new(coordinator: coordinator,
        request: request, operation: operation, result: result, error: nil)
    end

    [nil, :trace, :resume].each do |failure|
      it "installs committed state before tracing/FSM entry#{", including #{failure} failure (F0)" if failure}" do
        install(fsm_session_id: nil)
        submitted = hold_terminal_worker
        order = []
        runner = instance_double(Phronomy::Agent::ExecutionSessionRunner)
        allow(Phronomy::Agent::ExecutionSessionRunner).to receive(:new).and_return(runner)
        allow(Phronomy::Tracing::Automatic).to receive(:observe_task) do |task, *_, **_options|
          order << [:trace, task, observation]
          raise IOError, "trace failed" if failure == :trace
        end
        allow(runner).to receive(:resume_approval) do |context, task, **options|
          order << [:resume, task, observation, context, options]
          raise IOError, "resume failed" if failure == :resume
        end
        apply(ready)
        expect(order.map(&:first)).to eq((failure == :trace) ? [:trace] : [:trace, :resume])
        order.each do |_, task, observed|
          expect(task).to equal(resume_task)
          expect(observed).to include(root: next_root, admitted: true, tasks_done: [false, false])
          expect(observed[:state].execution).to equal(ready.result.execution)
        end
        if failure
          operation = submitted.fetch(0).call
          expect(operation.execution).to equal(ready.result.execution)
          expect(operation.expected_execution_revision).to eq(ready.result.execution.execution_revision)
          expect(operation.terminal_view.source_error.message).to eq("#{failure} failed")
          expect(operation.state_required).to be true
        else
          expect(submitted).to be_empty
          expect(order.last[3]).to equal(invocation)
          expect(order.last[4]).to eq(approved: true, config: ready.request.config)
        end
        expect(on_loop { registry.take_agent_completion_waiters(execution.execution_id) }).to eq([result_task, other_task, resume_task])
        expect(resume_task).not_to be_done
      end
    end
  end
end
