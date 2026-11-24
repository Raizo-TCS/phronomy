# Original-owner Agent approval recovery

G3a recovers one uncertain approval decision on the original live standalone Agent. The Agent owns the decision's meaning, its suspended wait, cancellation binding and continuation. Persistence proves what was saved; the Runtime serializes original-owner application and accounts for physical work. A caller's observation can fail without releasing any of those responsibilities.

For example, a report-reading Tool waits for a human decision. The decision transaction commits, but its response is lost. The stored execution has the decision while the live Agent still appears suspended. Repeating `approve` can duplicate intent, and loading another Agent does not repair the original live owner. An explicit recovery observation instead checks the exact saved state and completes that owner's transition.

Baseline: G3b-4 `b2f7c349215085983cfcc89097df9cdbaddef24d`. This document describes the G3a implementation candidate. Contract concept v55 and foundation v48 remain the canonical architectural boundaries. The delivery evidence identifies the final candidate and validation results.

## Keep the decision, owner transition and caller observation separate

An approval transaction and its reply are different facts. The retained operation captures immutable before/after evidence, the exact request and decision, original Store identity, and the original owner. It exposes `ApprovalRecoveryError` only while retaining the uncertain obligation. A later observation does not reopen the failed approval TaskResult.

For example, `approve_async` can fail with `ApprovalRecoveryError` while the original `invoke_async` observation remains attached to the execution. If reconciliation confirms the committed decision, the original invocation and a new execution observation may both receive the eventual result; the failed approval observation remains failed.

| Layer | Owns | Does not establish by itself |
| --- | --- | --- |
| Caller observation | Waiting, timeout and a result/error received by one caller | Transaction outcome, job cancellation or owner release |
| Approval persistence proof | The exact captured pre-state or post-state under the original Store's guard | Live application or continuation admission |
| Original Agent owner | Restoring the wait or applying the decision and retaining exact continuation sessions | Provider/Tool success merely because sessions were admitted |
| Runtime physical accounting | Completion of the tracked approval save/read workers and admitted sessions | Durable decision outcome from worker return alone |

The proof compares the root, execution, relevant journal evidence, journal head, retention evidence and cancellation evidence. A confirmed post-state additionally verifies the exact decision content bytes. Matching an execution revision alone is insufficient. Changed or conflicting evidence remains unresolved; an unavailable read does not become a guessed rollback.

For example, the correct request identifier with a different saved approval value must not authorize the retained continuation. Likewise, a changed cancellation marker prevents treating the old captured pre-state as current.

## Observe recovery through the original Agent

The capability is a process-local reference to one retained operation. Public identities support diagnostics; they do not reconstruct authority. Reconciliation reads approval persistence without retrying its writes. Applying confirmed post-state may start the first execution of the authorized Tool/provider continuation, so the operation is not generally free of business effects.

For example, a committed `approved: true` decision can release the previously waiting Tool to run once. A committed `approved: false` decision resumes the rejection path. Neither branch asks the application to repeat the decision merely because the response was lost.

| Method or value | Contract |
| --- | --- |
| `pending_approval_recovery(execution_id:)` | Local lookup on this exact Agent incarnation's existing registry; no persistence access, Runtime creation or coordinator creation. Requires a nonempty String. |
| `reconcile_approval_async(recovery:)` | Fresh `TaskResult<ApprovalRecoveryResult>` for explicit readback and original-owner application. |
| `reconcile_approval(recovery:)` | Blocking host-thread equivalent. The EventLoop reentrancy guard runs before starting an observation. |
| `ApprovalRecovery` | Frozen, privately constructed capability with `agent_id`, `execution_id`, `approval_request_id`, `recovery_id` and `approved` readers. |
| `ApprovalRecoveryError` | Retained responsibility with code `agent.approval_recovery`; `original_error` preserves the initial failure and `cause` the immediate failure. It is not a business-failure verdict. |

The capability's private operation, exact issued reference and owning Agent object must all match. Another Agent with the same durable identifier, a copied capability, or copied diagnostic strings does not grant recovery rights. No separate approval retry API is added.

For example, after an observer ends before receiving the recovery error, the application can retain its original Agent and execution identity, then use `pending_approval_recovery(execution_id:)` to find the still-owned obligation. Once that obligation resolves, pending lookup returns nil; an already held capability can still produce its final receipt.

## Interpret the receipt without confusing recovery with job completion

The immutable receipt separates persistence outcome, original-owner application, continuation progress and physical approval-worker completion. Resolving approval recovery leaves the same Agent job owned: it either waits again or continues execution.

For example, a receipt can be `confirmed_post` while application is still pending after a delivery failure. A later receipt may become `applied`/`resumed` while the approved Tool is still running. Both receipts preserve the same decision fact; neither claims that Tool work succeeded.

| Reader | Meaning |
| --- | --- |
| `recovery` and diagnostic identities, including `approved` | The same captured approval decision and process-local authority. |
| `outcome` | `confirmed_pre`, `confirmed_post`, `unresolved` or `unavailable`. |
| `application_state` | `pending` or `applied` by the original owner. |
| `continuation_state` | `pending`, `restored` or `resumed`. Restored means the same original wait; resumed means the retained continuation has been admitted or transferred to its terminal completion path. |
| `physical_complete?` | Whether the approval save and recovery read workers have stopped. This excludes the resumed Tool/provider work and whole Agent job. |
| `resolved?` | Physical approval completion plus applied state and restored/resumed continuation. |
| `revision` | Exact confirmed execution revision: original suspended revision for pre-state, saved approval revision for post-state; otherwise nil. |
| `execution_task` | Fresh independent observation of resumed execution, available only for confirmed post-state with applied/resumed continuation. |
| `error` | Recovery/read/application error, separate from the resumed execution's own result or error. |

Confirmed pre-state restores the same request, invocation, suspended cancellation binding and admission. It neither rewrites the decision nor releases the job. The application can request another explicit decision after receiving the restored wait. Confirmed post-state applies the captured decision and continues the same invocation, retaining exact parent/child session identities across partial registration.

For example, if the first Tool child was admitted and registration of a later child failed, recovery must not recreate or restart the first child. It resumes only missing registrations whose non-admission is known. Missing sessions observed later are not proof that earlier business effects never ran.

`resumed` includes an admitted continuation that subsequently fails or is cancelled; its execution observation reports the actual outcome. Repeated resolved receipts provide independent execution TaskResults. A timeout while waiting on one does not cancel the authorized work, and closing one observer does not settle the private canonical continuation task.

For example, a caller may time out while an approved report read is still running, then observe the same retained continuation through a later receipt. The Tool count must remain one, even though the application obtains two distinct execution observations.

## Keep normal application behavior equivalent

The complete normal application below is unchanged between the G3b-4 baseline and G3a candidate. Its deterministic adapter performs no network request; Runtime admission, the approval wait, transaction, Tool invocation and final result are real. The additional record reads are measurement scaffolding, not application recovery policy.

For example, the shared fixture asks for one approved report read, executes the Tool once, and returns `report ready`. To run either version, concatenate the shared setup, exactly one normal-function listing, and the shared driver. The source listings are checked byte-for-byte against the executed delivery helpers.

### Shared fixture setup

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"
require "timeout"

class G3aReportTool < Phronomy::Tool::Base
  tool_name "read_approved_report"
  description "Read the report after the exact human decision"
  requires_approval true
  class << self
    attr_accessor :calls
  end

  def execute
    self.class.calls += 1
    "approved report"
  end
end

class G3aReportAgent < Phronomy::Agent::Base
  agent_definition id: "approval-report", version: 1
  model "offline-model"
  tools G3aReportTool => nil
end

class G3aReportAdapter < Phronomy::LLMAdapter::Base
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @calls += 1
    if @calls == 1
      Phronomy::LLMAdapter::Response.new(tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "report-read", name: "read_approved_report", arguments: {})
      ], finish_reason: :tool_calls)
    else
      Phronomy::LLMAdapter::Response.new(content: "report ready", finish_reason: :stop)
    end
  end
end
```

### Before: G3b-4 baseline

This function contains the complete ordinary request, decision, observation and measurement flow.

<!-- example: normal-before -->
```ruby
# The application selects one exact approval request and makes one decision.
# The fixture adapter does not use a network; Runtime and persistence are real.
def run_approval_report
  G3aReportTool.calls = 0
  adapter = G3aReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  store = Phronomy::PersistenceComposition.in_memory.agent
  approvals = Queue.new
  agent = G3aReportAgent.create(agent_id: "approval-report", persistence: store,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
  invocation = agent.invoke_async("Read the report")
  request = Timeout.timeout(5) { approvals.pop }
  decision = agent.approve_async(request.execution_id, approval_request_id: request.id, approved: true)
  result = decision.wait_result(timeout: 5)
  original_result = invocation.wait_result(timeout: 5)
  execution = store.executions.load(request.execution_id)
  decisions = store.journals.read(agent.agent_id).select { |record| record.kind == :approval_decided }
  {
    output: result.fetch(:output), original_output: original_result.fetch(:output),
    execution_status: execution.status, execution_revision: execution.execution_revision,
    agent_revision: agent.agent_root.agent_revision, root_status: agent.agent_root.lifecycle_status,
    provider_calls: adapter.calls, tool_calls: G3aReportTool.calls,
    decisions: decisions.map { |record| store.contents.fetch_json(record.content_ref).fetch("approved") },
    decision_logical_complete: decision.done?, decision_physical_complete: decision.physical_complete?,
    invocation_logical_complete: invocation.done?, invocation_physical_complete: invocation.physical_complete?
  }
end
```

### After: G3a candidate

The application function is identical. Successful approval still returns the execution result through the decision observation and original invocation.

<!-- example: normal-after -->
```ruby
# The application selects one exact approval request and makes one decision.
# The fixture adapter does not use a network; Runtime and persistence are real.
def run_approval_report
  G3aReportTool.calls = 0
  adapter = G3aReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  store = Phronomy::PersistenceComposition.in_memory.agent
  approvals = Queue.new
  agent = G3aReportAgent.create(agent_id: "approval-report", persistence: store,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
  invocation = agent.invoke_async("Read the report")
  request = Timeout.timeout(5) { approvals.pop }
  decision = agent.approve_async(request.execution_id, approval_request_id: request.id, approved: true)
  result = decision.wait_result(timeout: 5)
  original_result = invocation.wait_result(timeout: 5)
  execution = store.executions.load(request.execution_id)
  decisions = store.journals.read(agent.agent_id).select { |record| record.kind == :approval_decided }
  {
    output: result.fetch(:output), original_output: original_result.fetch(:output),
    execution_status: execution.status, execution_revision: execution.execution_revision,
    agent_revision: agent.agent_root.agent_revision, root_status: agent.agent_root.lifecycle_status,
    provider_calls: adapter.calls, tool_calls: G3aReportTool.calls,
    decisions: decisions.map { |record| store.contents.fetch_json(record.content_ref).fetch("approved") },
    decision_logical_complete: decision.done?, decision_physical_complete: decision.physical_complete?,
    invocation_logical_complete: invocation.done?, invocation_physical_complete: invocation.physical_complete?
  }
end
```

### Shared measurement driver

Set `G3A_NORMAL_REPORT` and `G3A_NORMAL_SOURCE` to output paths, then run the assembled file using the tested checkout's bundled Ruby dependencies. The source report identifies the loaded implementation; the functional report excludes random execution identifiers and timestamps.

<!-- example: normal-driver -->
```ruby
if $PROGRAM_NAME == __FILE__
  begin
    report = run_approval_report
    raise "Unexpected result" unless report[:output] == "report ready" && report[:original_output] == "report ready"
    raise "Unexpected business replay" unless report[:provider_calls] == 2 && report[:tool_calls] == 1
    raise "Unexpected approval decision count" unless report[:decisions] == [true]
    File.write(ENV.fetch("G3A_NORMAL_REPORT"), JSON.pretty_generate(report) + "\n")
    File.write(ENV.fetch("G3A_NORMAL_SOURCE"), JSON.pretty_generate({
      application: method(:run_approval_report).source_location,
      approval_commit: Phronomy::Agent::ApprovalResumeCommit.instance_method(:commit).source_location,
      gem: Gem.loaded_specs.fetch("phronomy").full_gem_path
    }) + "\n")
  ensure
    Phronomy.reset_runtime!
  end
end
```

The baseline and candidate functional JSON reports are exactly equal. This comparison establishes the measured successful path; it does not claim fault-path equivalence or equivalence for every provider/backend.

For example, both reports contain the following complete observation, including separate decision/invocation logical and physical completion:

```json
{
  "output": "report ready",
  "original_output": "report ready",
  "execution_status": "completed",
  "execution_revision": 6,
  "agent_revision": 4,
  "root_status": "idle",
  "provider_calls": 2,
  "tool_calls": 1,
  "decisions": [
    true
  ],
  "decision_logical_complete": true,
  "decision_physical_complete": true,
  "invocation_logical_complete": true,
  "invocation_physical_complete": true
}
```

## Add explicit handling only for the uncertain decision path

The following complete helper makes one decision and, only after `ApprovalRecoveryError`, performs one explicit reconciliation. It returns a restored request, a resumed execution observation, or retained pending recovery. It does not loop, automatically write another decision, transfer ownership or manufacture a replacement Agent.

For example, a rolled-back decision returns `approval_required` with the original request so the application can obtain or confirm another human decision. A committed decision returns `resumed` with an execution TaskResult. If readback is unavailable, the caller retains the Agent and capability and chooses when to observe again.

<!-- example: recovery-handler -->
```ruby
# frozen_string_literal: true

require "phronomy"

# The caller owns the Agent, original invocation and unresolved references.
# Recovery may start the already authorized Tool for its first execution.
# A confirmed pre-state is returned for a separate human decision; this function
# never automatically submits another approval write.
def decide_with_recovery(agent:, request:, approved: true)
  result = agent.approve(request.execution_id, approval_request_id: request.id, approved: approved)
  {state: :completed, result: result}.freeze
rescue Phronomy::Agent::ApprovalRecoveryError => failure
  recovery = failure.recovery
  receipt = agent.reconcile_approval(recovery: recovery)
  if receipt.resolved? && receipt.continuation_state == :restored
    {state: :approval_required, request: request, recovery: recovery, receipt: receipt}.freeze
  elsif receipt.resolved? && receipt.continuation_state == :resumed
    {state: :resumed, execution_task: receipt.execution_task, recovery: recovery, receipt: receipt}.freeze
  else
    {state: :recovery_pending, recovery: recovery, receipt: receipt}.freeze
  end
end
```

The helper's `completed` tag means the ordinary decision observation returned its result; the application must inspect that result as usual, including a rejection result's `rejected: true`. `resumed` means an observation exists for continued work, not that work succeeded. The caller remains responsible for retaining the original Agent, the original invocation handle and any unresolved recovery reference.

For example, after `resumed`, waiting on `execution_task` can return a completed/failed saved execution or raise an operation/observation error according to the existing exact-result contract. After `recovery_pending`, the application can call `reconcile_approval` again with the same capability when observation is appropriate. It must not blindly call the decision helper again while the original transition remains unresolved.

| Trigger | Baseline behavior observed in review | G3a behavior |
| --- | --- | --- |
| Ordinary successful decision | One saved decision, one Tool execution and final result | Same application and equal functional report |
| Decision commits, reply is lost | Saved state advances while the original live wait/admission remains inconsistent | Retained error/capability; explicit proof can apply the saved decision and start its continuation once |
| Decision transaction rolls back | Original wait can remain blocked behind a recovery-required admission with cancellation unbound | Explicit confirmed pre-state restores the same wait and cancellation binding without another decision write |
| Proof unavailable or conflicting | No reliable classification from the original failure alone | `unavailable` or `unresolved`; responsibility stays retained |
| Original owner has stopped | A different Runtime cannot safely repair the old owner's local transition | Unavailable receipt and incomplete cleanup; no fabricated successful release |

## Preserve the bounded implementation scope

G3a covers an installed standalone Agent's original live invocation at its approval wait. Hosted/detached Agents, participant or reserved execution, execution extensions, parent-owned waits and cross-process recovery retain their existing separate contracts. It does not add general approval rehydration or a generic distributed retry protocol.

For example, an approval owned by an Orchestrator/Team participant must continue through that domain's existing coordination path. A saved request identifier is not permission for this original-owner capability API to take over a detached execution.

Recovery can finish on the original running or draining Runtime. A stopped owner cannot be replaced through these methods, and unresolved responsibility prevents complete cleanup. Positive mechanism evidence that the initial save was never admitted can restore the ordinary wait and preserve the ordinary error; a missing handle or generic submission exception does not establish that evidence.

For example, shutdown while an uncertain save/read still has physical work cannot report successful release merely because its waiting TaskResult ended. Conversely, a confirmed restored wait remains an active Agent job whose ordinary cancellation and shutdown obligations continue.

The backend must establish that the prior transaction has settled and authoritative readback is ordered after it, with the Store's guard and atomicity guarantees intact. Local worker quiescence, a matching revision or an in-memory test does not prove these properties for every remote database. There is no claim of exactly-once external effects after a process crash.

For example, a database whose late commit can occur after an unguarded read cannot safely classify that read as a final pre-state. Its adapter must provide the required ordering and exclusion before this recovery contract applies.

## Validate the protocol and the actual application separately

The finite [approval recovery model](../../spec/models/approval_decision_recovery/README.md) checks stated safety/liveness properties under explicit premises. Real Runtime fault-injection tests check whether implementation follows those rules. Neither substitutes for backend conformance or an actual application comparison.

For example, model checks can reject release before physical completion or replay of an admitted child. Integration tests must still inject commit-response loss, rollback, read failure, cancellation, partial session admission and owner shutdown through the real Agent/Runtime path.

The delivery's documented-application tests execute the exact helper above on ordinary success, confirmed pre-state, committed positive/negative decisions, unavailable readback and stopped-owner cases. A gated real Tool also checks that physical approval completion can precede job completion and that later receipts return fresh execution observations without another Tool call. The normal reports come from executing the identical complete application on both framework versions, not from rewriting expected JSON.

The implementation reuses neutral execution and persistence primitives, but it does not share the complete retained-owner algorithm. Source review found meaningful duplicated physical-attempt bookkeeping in the terminal and approval owners: approximately 72 nonblank, noncomment lines per owner, including an approximately 48-line common watch/refresh core. This is substantial enough to justify a bounded follow-up; no source-line reduction is claimed for the current implementation.

A neutral `PhysicalAttempt` mailbox is the smallest identified extraction candidate once both owners' failure paths have stabilized. It should expose explicit facts and hooks through a real helper interface, rather than a mixin coupled to owner instance variables. Observation policy, write-retry authority, continuation decisions and release remain with their domain owners. Terminal recovery can release a terminal job; approval recovery restores or resumes the same owned job.

For example, extracting a helper that always releases Agent admission after successful proof would be correct for some terminal paths and wrong for this restored approval wait. Any later common abstraction must preserve that distinction while reducing actual duplicate implementation and test burden.
