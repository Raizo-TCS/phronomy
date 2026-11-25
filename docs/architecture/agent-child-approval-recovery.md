# Original-owner approval recovery for child and restored waits

The Agent that owns an approval decision retains its saved outcome and continuation even when the wait belongs to a coordinated child or was restored from persistence. A hosted parent additionally owns the authority to answer that child's wait and to detach a later wait. G3d extends the existing approval recovery operation to those relationships; it does not introduce a second job manager.

For example, a report service starts a reviewer child, releases both local owners at the first approval, and restores them on another host. The host approves the first report, but the successful decision transaction's reply is lost. Recovery must apply that exact decision once, allow the second report to request approval, and give the host a valid handle for releasing that next wait.

Baseline: applied G3c `c9b2f3d8f989aab87f7e04feafeb9e35f0c0763a`. This document describes the G3d implementation candidate. Contract concept v55 and foundation v48 remain the architectural references. Final commit identity, validation and limits are recorded in the delivery evidence.

## Keep the child decision and hosted authority together

A child owns its approval state, cancellation and execution. Its parent's saved coordination wait authorizes a hosted decision for one exact child. The recovery owner retains both facts while distinguishing saved-state proof, local application, continuation admission and each caller's observation.

For example, a readable child post-state does not by itself permit dispatch if the parent revision, child slot content, retention or cancellation facts no longer match the captured authority. Likewise, a previous `confirmed_post` receipt remains historical knowledge of the decision while a later handoff can remain pending after authority changes.

| Path | Retained owner and proof | Continuation observation |
| --- | --- | --- |
| Existing live standalone wait | Original Agent, invocation and cancellation binding; complete approval pre/post evidence | Existing independent `execution_task` |
| Direct correlated child decision | Exact child incarnation and reservation, complete child evidence and retained references | Existing independent `execution_task`; no hosted detach capability is invented |
| Restored standalone wait | Exact loaded Agent and reconstructed invocation; no earlier live cancellation binding is assumed | Existing independent `execution_task` |
| Restored parent using `approve_hosted_child` | Exact child plus the original recovered parent wait; guarded immutable parent/child authority capture | Independent `execution_task` and, while authority remains available, `hosted_invocation` |

The hosted evidence is captured before asynchronous submission using the existing relation reader in an outer guarded transaction. Later persistence checks compare the complete captured parent footprint and validate the child decision separately. Owner application checks the same local parent wait and child incarnation on EventLoop. No arbitrary participant callback is replayed to infer a save outcome.

The storage check is a snapshot under the selected Store's guard, not a distributed fence held until external dispatch. The guarantee depends on the existing cooperative-writer and cancellation protocol. Concurrent external mutation after a validated snapshot is not a new cross-process exactly-once guarantee.

## Recover through the same child API

A recovery capability identifies the original child that owns the uncertain decision. Existing process-local lookup and approval reconciliation are sufficient to reach that owner; a parent does not gain permission to reconstruct another child's capability from identifiers.

For example, after `decision.wait_result` raises `ApprovalRecoveryError`, the host can use `Agent::Base.live_for_execution(error.execution_id)` and call that child's `reconcile_approval(recovery: error.recovery)`. Wrong-incarnation and copied-capability checks remain unchanged. Reconciliation observes and applies the original decision; it never makes that decision again.

| Public operation or value | G3d behavior |
| --- | --- |
| `pending_approval_recovery(execution_id:)` | Same local lookup; supported child/restored obligations now remain discoverable |
| `reconcile_approval[_async](recovery:)` | Same sync/async contract and process-local capability; no new parent reconciliation facade |
| `ApprovalRecoveryResult#execution_task` | Fresh independent observation after a resolved post-state; a successful hosted detach completes it with `ApprovalWait` |
| `ApprovalRecoveryResult#hosted_invocation` | New optional `HostedInvocation` for the recovered hosted continuation; it has its own independent observation and the exact private detach authority |
| `HostedInvocation#wait_result / #on_complete / #detach!` | Existing public methods; a fresh recovered handle preserves the next-wait detach behavior |

A hosted handle is available only for a resumed hosted continuation while the original authority can still be represented. It is nil for direct child and standalone recovery, before continuation admission, after canonical physical completion retires the authority, or when the original host is no longer available. A historical resolved receipt can still provide `execution_task` after `hosted_invocation` becomes nil. An earlier receipt's handle keeps its result observation, but later detach attempts fail once its authority ends.

## Separate observations from detach rights

The original failed decision observation remains closed. Each recovery receipt supplies fresh observations, while the private canonical continuation owns the physical lifetime and exact detach right. Closing an observation does not cancel that continuation or authorize another dispatch.

For example, cancelling `receipt.execution_task` does not prevent `receipt.hosted_invocation` from observing the next wait and detaching it. Both observations are distinct from the canonical detach task. Two fresh handles can refer to the same continuation, but only a matching, still-owned wait can be detached; the first successful release makes subsequent attempts stale.

Normal successful hosted calls retain their existing handle behavior. Internally, a still-open original decision handle follows its exact continuation when its operation lease is handed over. The detach command resolves that bridge on EventLoop. A failed or cancelled original observation cannot use the bridge to adopt a recovered continuation.

Physical completion of the canonical continuation retires the captured reader, saved parent evidence and live-owner references. Existing recovered handles drop detach authority while retaining their result observation. This does not apply to an original `start_hosted` parent handle: that handle must retain its authority after the parent's committed coordination wait so that the host can detach the child.

## Preserve the normal application

The normal report workflow retains the same inputs, two human decisions, two wait transfers, outputs and release policy before and after G3d. The framework removes the unsupported recovery gap; the application still chooses each approval and controls its external claim and retry policy.

For example, both versions below run five deterministic Provider calls, execute each report Tool once, finish both saved executions and release the completed pair. The extra response-loss fixture is disabled for this equivalence comparison. Runtime, Store and native parent/child coordination are real; the Provider is offline.

### Shared setup

The shared setup defines both Agent roles, one approval Tool, the deterministic Provider, the event queue and the selected in-memory stores. The optional transaction wrapper injects only a lost reply after a real successful save.

For example, the Provider asks the parent to dispatch the reviewer, then asks the reviewer for the first and second report in sequence. Tool effects are recorded so the comparison detects repeated business work.

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"
require "timeout"

class G3dReviewTool < Phronomy::Tool::Base
  tool_name "review_report"
  description "Read one report after its human approval"
  requires_approval true

  class << self
    attr_accessor :effects
  end

  def execute(query:)
    self.class.effects << query
    "reviewed #{query}"
  end
end

class G3dReviewAgent < Phronomy::Agent::Base
  agent_definition id: "hosted-report-reviewer", version: 1
  model "offline-model"
  tools G3dReviewTool => nil
end

class G3dReportOrchestrator < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "hosted-report-parent", version: 1
  model "offline-model"
  subagent :reviewer, G3dReviewAgent
end

class G3dReportAdapter < Phronomy::LLMAdapter::Base
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @calls += 1
    name, arguments = case @calls
    when 1 then ["dispatch_to_reviewer", {input: "Review both reports"}]
    when 2 then ["review_report", {query: "first report"}]
    when 3 then ["review_report", {query: "second report"}]
    when 4
      return Phronomy::LLMAdapter::Response.new(content: "reviews ready", finish_reason: :stop)
    when 5
      return Phronomy::LLMAdapter::Response.new(content: "report ready", finish_reason: :stop)
    else
      raise "Unexpected repeated Provider work"
    end
    Phronomy::LLMAdapter::Response.new(tool_calls: [
      Phronomy::Tool::CallRequest.new(id: "call-#{@calls}", name: name, arguments: arguments)
    ], finish_reason: :tool_calls)
  end
end

# This optional fault injector loses a successful transaction's reply. The
# transaction and Runtime are real; no Provider or Tool calls are mocked.
module G3dLostApprovalResponse
  attr_accessor :lose_next_approval_response

  def transaction(&block)
    armed = @lose_next_approval_response
    @lose_next_approval_response = false if armed
    result = super(&block)
    raise IOError, "Approval response lost after commit" if armed
    result
  end
end

def build_report_host
  G3dReviewTool.effects = []
  adapter = G3dReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  stores.agent.extend(G3dLostApprovalResponse)
  approvals = Queue.new
  options = {
    persistence: stores.agent, coordination_store: stores.multi_agent,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required }
  }
  parent = G3dReportOrchestrator.create(agent_id: "hosted-report-parent", **options)
  [adapter, stores, approvals, options, parent]
end
```

### Complete normal functions before and after

Both functions below contain the complete host sequence from the first reservation through the final release. Each catches a coordination-wait signal and still requires the matching guarded detach operation; an exception by itself is not treated as proof of a transferable wait.

For example, the second host answers the first report, then releases the next wait so a third host can make the second decision. Either column can be combined with the shared setup and driver using the default normal scenario.

<table><thead><tr><th>Before: applied G3c</th><th>After: G3d candidate</th></tr></thead><tbody><tr><td><!-- example: normal-before --><pre><code># The host explicitly hands over each committed wait and decides each approval.
def run_hosted_report
  adapter, stores, approvals, options, parent = build_report_host
  parent_id = &quot;hosted-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  start = parent.start_hosted(reservation: reservation, input: &quot;Prepare the report&quot;)
  first = Timeout.timeout(5) { approvals.pop }
  begin
    start.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The native parent committed its coordination wait; detach validates it.
  end
  start.detach!(execution_id: first.execution_id, approval_request_id: first.id)

  middle = G3dReportOrchestrator.load(parent.agent_id, **options)
  restore = middle.resume_async(parent_id)
  restored = Timeout.timeout(5) { approvals.pop }
  raise &quot;Approval identity changed&quot; unless restored.id == first.id
  begin
    restore.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The restored parent owns the same child&#x27;s saved wait.
  end
  decision = middle.approve_hosted_child(parent_id, execution_id: first.execution_id,
    approval_request_id: first.id, approved: true)
  second = Timeout.timeout(5) { approvals.pop }
  wait = decision.detach!(execution_id: second.execution_id, approval_request_id: second.id)
  raise &quot;Detach observation changed&quot; unless decision.wait_result(timeout: 5) == wait

  last = G3dReportOrchestrator.load(parent.agent_id, **options)
  restore = last.resume_async(parent_id)
  restored = Timeout.timeout(5) { approvals.pop }
  raise &quot;Second approval identity changed&quot; unless restored.id == second.id
  begin
    restore.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The next host makes the second decision explicitly.
  end
  child_result = last.approve_hosted_child(parent_id, execution_id: second.execution_id,
    approval_request_id: second.id, approved: true).wait_result(timeout: 5)
  parent_result = last.resume(parent_id)
  released = last.unload_with_completed_child!(parent_id, execution_id: second.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3dReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, second.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, second.execution_id].map { |id| stores.agent.executions.load(id).execution_revision }
  }
end</code></pre></td><td><!-- example: normal-after --><pre><code># The host explicitly hands over each committed wait and decides each approval.
def run_hosted_report
  adapter, stores, approvals, options, parent = build_report_host
  parent_id = &quot;hosted-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  start = parent.start_hosted(reservation: reservation, input: &quot;Prepare the report&quot;)
  first = Timeout.timeout(5) { approvals.pop }
  begin
    start.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The native parent committed its coordination wait; detach validates it.
  end
  start.detach!(execution_id: first.execution_id, approval_request_id: first.id)

  middle = G3dReportOrchestrator.load(parent.agent_id, **options)
  restore = middle.resume_async(parent_id)
  restored = Timeout.timeout(5) { approvals.pop }
  raise &quot;Approval identity changed&quot; unless restored.id == first.id
  begin
    restore.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The restored parent owns the same child&#x27;s saved wait.
  end
  decision = middle.approve_hosted_child(parent_id, execution_id: first.execution_id,
    approval_request_id: first.id, approved: true)
  second = Timeout.timeout(5) { approvals.pop }
  wait = decision.detach!(execution_id: second.execution_id, approval_request_id: second.id)
  raise &quot;Detach observation changed&quot; unless decision.wait_result(timeout: 5) == wait

  last = G3dReportOrchestrator.load(parent.agent_id, **options)
  restore = last.resume_async(parent_id)
  restored = Timeout.timeout(5) { approvals.pop }
  raise &quot;Second approval identity changed&quot; unless restored.id == second.id
  begin
    restore.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The next host makes the second decision explicitly.
  end
  child_result = last.approve_hosted_child(parent_id, execution_id: second.execution_id,
    approval_request_id: second.id, approved: true).wait_result(timeout: 5)
  parent_result = last.resume(parent_id)
  released = last.unload_with_completed_child!(parent_id, execution_id: second.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3dReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, second.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, second.execution_id].map { |id| stores.agent.executions.load(id).execution_revision }
  }
end</code></pre></td></tr></tbody></table>

### Complete recovery function

The recovery function intentionally changes only the lost-response path. It keeps the first approval decision and resolves that same saved transition, then uses the recovered hosted handle for the second wait. An unresolved receipt leaves the claim with the application instead of causing automatic replay.

For example, the injected transaction commits the first approval and raises before returning. The function requires confirmed post-state, resolved continuation and an available hosted handle together. It verifies that the failed original observation remains failed and that both fresh observations receive the successful detach receipt.

<!-- example: recovery-example -->
```ruby
# Recovery resolves the first decision without making that decision again.
def run_hosted_report_with_recovery
  adapter, stores, approvals, options, parent = build_report_host
  parent_id = "hosted-report-execution"
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  start = parent.start_hosted(reservation: reservation, input: "Prepare the report")
  first = Timeout.timeout(5) { approvals.pop }
  begin
    start.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # A matching committed wait, not the error alone, permits this detach.
  end
  start.detach!(execution_id: first.execution_id, approval_request_id: first.id)

  middle = G3dReportOrchestrator.load(parent.agent_id, **options)
  restore = middle.resume_async(parent_id)
  restored = Timeout.timeout(5) { approvals.pop }
  raise "Approval identity changed" unless restored.id == first.id
  begin
    restore.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The original parent and child now own this restored coordination wait.
  end
  stores.agent.lose_next_approval_response = true
  decision = middle.approve_hosted_child(parent_id, execution_id: first.execution_id,
    approval_request_id: first.id, approved: true)
  failure = begin
    decision.wait_result(timeout: 5)
    raise "The injected response loss was not observed"
  rescue Phronomy::Agent::ApprovalRecoveryError => error
    error
  end
  child = Phronomy::Agent::Base.live_for_execution(failure.execution_id)
  receipt = child.reconcile_approval(recovery: failure.recovery)
  unless receipt.outcome == :confirmed_post && receipt.resolved? && receipt.hosted_invocation
    raise "Retain the claim: approval or hosted continuation is still unresolved"
  end
  recovered = receipt.hosted_invocation
  second = Timeout.timeout(5) { approvals.pop }
  wait = recovered.detach!(execution_id: second.execution_id, approval_request_id: second.id)
  raise "Recovered detach observation changed" unless recovered.wait_result(timeout: 5) == wait
  raise "Execution observation changed" unless receipt.execution_task.wait_result(timeout: 5) == wait
  begin
    decision.wait_result(timeout: 5)
    raise "The original failed observation reopened"
  rescue Phronomy::Agent::ApprovalRecoveryError => original
    raise "The original failure changed" unless original.equal?(failure)
  end

  last = G3dReportOrchestrator.load(parent.agent_id, **options)
  restore = last.resume_async(parent_id)
  restored = Timeout.timeout(5) { approvals.pop }
  raise "Second approval identity changed" unless restored.id == second.id
  begin
    restore.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # Only this next host issues the second, distinct approval decision.
  end
  child_result = last.approve_hosted_child(parent_id, execution_id: second.execution_id,
    approval_request_id: second.id, approved: true).wait_result(timeout: 5)
  parent_result = last.resume(parent_id)
  released = last.unload_with_completed_child!(parent_id, execution_id: second.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3dReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, second.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, second.execution_id].map { |id| stores.agent.executions.load(id).execution_revision },
    recovery_outcome: receipt.outcome, continuation_state: receipt.continuation_state
  }
end
```

### Shared executable driver

The driver chooses one complete function and shuts down the Runtime after the observation finishes. It is verification scaffolding; production claim ownership and worker supervision remain application responsibilities.

For example, concatenate the shared setup, one normal function and this driver for the normal comparison. For the fault case, concatenate the setup, recovery function and driver, then set `G3D_SCENARIO=recovery`. The selected branch alone is executed.

<!-- example: shared-driver -->
```ruby
if $PROGRAM_NAME == __FILE__
  begin
    result = ENV.fetch("G3D_SCENARIO", "normal") == "recovery" ?
      run_hosted_report_with_recovery : run_hosted_report
    puts JSON.pretty_generate(result)
  ensure
    Phronomy.reset_runtime!
  end
end
```

## Preserve symmetry and state the intentional differences

The added behavior extends the existing approval recovery capability rather than creating another set of reconciliation methods. The hosted result adds a separate capability because a result observation and the authority to detach a parent/child pair have different lifetimes.

For example, making `execution_task` a hosted handle would break callers that use TaskResult cancellation and callbacks. Instead it remains a TaskResult, while the optional hosted handle carries the exact existing detach contract.

| Comparison | Decision | Reason |
| --- | --- | --- |
| Ordinary, child and restored approval lookup/reconciliation | Adopt existing names, arguments, outcomes and sync/async methods | They resolve the same captured approval decision |
| Approval reconciliation versus terminal/dispatch retry | Keep approval readback without a new retry method | Confirmed pre-state restores the original wait; the application may issue a fresh explicit decision |
| `execution_task` versus `hosted_invocation` | Add the optional hosted reader | Observation cancellation must not spend or recreate detach authority |
| Parent-level reconciliation facade | Withdraw | Existing `live_for_execution` reaches the exact child; another facade would add no authority |
| Reusing the failed original hosted handle | Reject | A closed observation must not silently adopt a later canonical continuation |
| Arbitrary participant replay or new generic manager | Defer outside this change | Captured child/hosted approval proof does not establish participant-specific commit semantics |

| Trigger | Applied G3c | G3d candidate |
| --- | --- | --- |
| Lost reply to a supported direct correlated child approval | Live owner remains busy without retained approval lookup | Explicit recovery retains and applies the same decision |
| Lost reply after a restored standalone approval | Original loaded wait lacks the required live binding | Existing approval recovery supports the exact restored invocation |
| Lost hosted child decision reply followed by another approval | No recovered hosted continuation with detach authority | Receipt can supply a fresh handle for the exact next wait |
| Parent authority changes during unresolved hosted recovery | No general recovery guarantee | Readback/application remain pending; historical saved-decision knowledge does not grant new authority |

## Bound validation and remaining work

The executable examples establish normal behavior equivalence and one concrete saved-response-loss continuation. Fault tests and the finite model separately cover retained ownership, changed evidence, cancellation, rejected delivery and physical lifetime. Their counts and exact source identities are recorded in the delivery evidence.

For example, a recovered hosted run must execute each report Tool once, preserve the original failed observation, detach the second wait and complete the parent after the next explicit decision. An invalid parent revision or mismatched relation must keep the obligation retained instead of attempting that business work.

This closes the implemented child/restored approval paths only. Participant-aware dispatch and terminal recovery remain within residual group 1; failed-Runtime administration and selected durable-backend acceptance remain their existing groups. It does not claim all G3 work, process-loss recovery, arbitrary extension support, or real external Provider acceptance is complete. Contract directions remain Agent to Execution/Persistence; new Agent proof and handle objects do not call concrete MultiAgent coordination implementations.
