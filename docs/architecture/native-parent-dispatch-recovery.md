# Native parent dispatch recovery

A native coordinating Agent owns its unfinished execution and the next Provider or Tool continuation. Its native participant owns child reservations, result-import decisions and the durable facts that connect those children to the parent. This increment extends original-owner dispatch recovery across that boundary while keeping those responsibilities separate.

For example, a report Orchestrator reserves a report child, or imports that child's completed report before asking its Provider for the final response. If the parent dispatch prerequisite commits but its response and immediate readback are unavailable, the original parent retains the captured operation. Recovery establishes the saved fact and checks the child's current authority before the original continuation can start.

Baseline: applied G3f commit `56e0e5bfedc5715749d9f10d1ddab11654d02db2`, tree `299dc7d7fe4996136eec5b77612a5413c98ef8d7`. This document describes the G3g implementation candidate, not its later application acceptance. Contract concept v55 and foundation v48 remain the architectural references. The [Agent dispatch contract](agent-dispatch-recovery.md) defines the existing public capability, receipt and observation semantics.

G3g was subsequently applied as `44288e1239701bf16aa67854a48c830b7295e2d4`. G3h adds [native final/wait and own approval recovery](native-parent-outcome-recovery.md). The G3g application source, baseline findings and operation-specific exclusions below remain its historical evidence; they do not claim that the later outcome work was already covered by dispatch recovery.

## Keep native decisions with the native owner

The generic Agent retains one operation and applies its eventual outcome through its original Runtime owner. The native participant supplies a detached persistence plan for its own domain. The plan contains immutable captured facts; it does not preserve a live participant callback or grant permission to run native coordination decisions again.

For example, a Tool prerequisite creates an exact child slot and the parent's retention hold. A retry saves the same captured extension content, the same allowed hold addition and the same Agent execution. It does not reserve a different child, repeat knowledge projection, reinterpret `on_error`, import a newly observed child result or call the original participant's commit method again.

| Responsibility | Owner | Captured or checked facts |
| --- | --- | --- |
| Preparation and next continuation | Original Agent and FSMSession | Captured Provider input or Tool batch; execution, operation and session identity; unused continuation right |
| Parent barrier proof | Agent Store and detached evidence | Complete parent root/execution/journal/content/cancellation footprint plus native parent retention evidence |
| Native persistence plan | Native participant | Exact captured extension bytes and bounded parent-hold addition reconstructed from the original before/after evidence |
| Child continuation authority | Native participant under ordered Store guards | Current root/execution and saved definition identity, exact native reservation/correlation, required hold and allowed terminal/absent state |
| Retry policy and unresolved capability lifetime | Application | Whether and when to request a persistence-only retry; retention of the original parent and capability |
| Result delivery and physical completion | Original Runtime and existing retained-operation machinery | Independent observations, worker completion and one-time continuation handoff |

The optional participant capability is private and limited to the native coordinator. Generic Agent code treats its plan as opaque and does not interpret native child slots or Handoff routing. Custom participants and Handoff participants do not acquire retained recovery merely by providing the ordinary synchronous participant callbacks.

For example, a Handoff Source transfer has routing, holds and a transfer receipt beyond a native child reservation. It requires its own domain proof and current-routing authority; the native plan cannot certify that transfer.

## Separate saved history from current continuation authority

A saved parent barrier and permission to continue it are different propositions. The complete captured parent footprint classifies the original write as pre-state, post-state or unknown. A fresh native-domain check determines whether its still-unused continuation can act on the children now. A known committed parent write remains a historical fact when a later child mutation blocks continuation.

For example, reconciliation may prove that a parent's child-import prerequisite committed. If that child has since been replaced or become active under a conflicting identity, recovery must preserve the confirmed parent history while withholding the new Provider dispatch. Changing the receipt to confirmed pre-state or writing the barrier again would misrepresent the saved history.

| Captured child relationship | Current authority required before first continuation |
| --- | --- |
| Already imported child | The exact terminal child with its native parent/slot correlation and required retained-history hold |
| Previously reserved, unimported child | The exact terminal child with matching authority, or both its root and execution fully absent as permitted by the saved reservation |
| Newly captured child slot | Both the exact child root and execution absent before admission |
| Active, suspended, replaced or incompletely absent child | Continuation is blocked; a partial record or matching identifier alone does not grant authority |

The current child check establishes identity, saved definition, terminal status, correlation and the required hold; it does not capture a new byte-for-byte child-result receipt. It relies on the existing immutable terminal-history contract. Unrelated holds or cancellation intent do not erase an exact terminal child history; the required native hold must still be present. Reconciliation and retry perform these checks again before the first continuation, including when post-state was remembered by an earlier attempt. A known-post retry is read-only. Conflicting or unavailable current evidence leaves the continuation unadmitted; the application retains the original capability and receives the existing receipt/error shape.

For example, a first read can establish post-state while result delivery is delayed. A second observation must still inspect the child before admitting the original Tool. Remembering post-state is useful for historical accuracy, but does not bypass the child check or authorize a second external call.

## Bound the persistence-only retry

The retry is one guarded transaction over captured parent effects. Parent and existing affected child-root guards are acquired in a stable order, the exact original pre-state is checked, and the native plan restores only its bounded immutable writes together with the captured Agent execution. The Store cannot guard an absent child root; new-child root and execution absence are checked inside that same transaction. A failed or incomplete proof cannot be repaired by repeating preparation or participant business logic.

For example, a rolled-back Tool prerequisite leaves no new child root or execution. An explicit retry can restore its captured reservation content and parent hold, save the captured dispatch execution, and verify the resulting complete post-state. If a child appeared in the meantime, that same retry is refused rather than adopting the new child.

The storage contract must provide settled prior attempts, authoritative ordered readback, atomic transactions and exclusion for all ordered guards. The model's `StableRead` premise excludes conflicting parent-proof or child-authority mutation between the guarded snapshot and continuation admission. The absence check is not a distributed reservation of an absent child identity. Transaction isolation and exclusion of unauthorized competing writers remain Store and integration obligations; a process-local lock or a stopped worker alone does not establish them for a remote backend.

For example, an old database transaction that may still commit after a reported pre-state defeats a guarded retry unless the backend first establishes its settlement. Likewise, releasing guards before external dispatch is correct only under the stated original-owner and admission protocol; the implementation does not hold database locks across Provider calls or Tool execution.

A retry does not rewrite root or journal history, reconstruct content from current mutable state, recreate a child or release child-history holds. The exact plan and complete post-state verification bound the write set. Any additional backend or external-service guarantee needs separate acceptance evidence.

For example, adding another retention reference is not permission to broaden the captured retry into a hold cleanup. History release remains the existing native lifetime policy, after exact parent/child custody and local physical-work checks.

## Preserve the ordinary report application

The application continues to create one parent, observe the child's approval, approve that exact child and receive the same report. It owns approval policy and final pair release. Dispatch recovery adds an explicit uncertain-save branch without requiring the application to parse native extensions, reconstruct child reservations or replay its report request.

For example, the tested report application uses an offline Provider adapter and a report Tool whose counter exposes repeated work. Its normal baseline and candidate executions follow the same public source and produce the same output and effects. Fault cases intentionally differ: the candidate exposes retained dispatch responsibility and can continue that original parent.

### Shared report service

The parent and child definitions, Provider adapter, Tool effect counter and approval listener form the same application on both sides. The adapter sends no network request; the Agent, Store and Runtime are real. The shared setup below requires `phronomy`, `json` and Ruby's `timeout` library.

For example, the first Provider response reserves the reviewer, the reviewer requests approval for one report read, and the final responses are `review ready` and `report ready`. The approval event supplies the exact child identity used by the application.

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"
require "timeout"

class G3gReviewTool < Phronomy::Tool::Base
  tool_name "review_one_report"
  description "Read the approved report once"
  requires_approval true

  class << self
    attr_accessor :effects
  end

  def execute(query:)
    self.class.effects << query
    "reviewed #{query}"
  end
end

class G3gReviewAgent < Phronomy::Agent::Base
  agent_definition id: "child-execution-reviewer", version: 1
  model "offline-model"
  tools G3gReviewTool => nil
end

class G3gReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "child-execution-parent", version: 1
  model "offline-model"
  subagent :reviewer, G3gReviewAgent
end

class G3gReportAdapter < Phronomy::LLMAdapter::Base
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @calls += 1
    name, arguments = case @calls
    when 1 then ["dispatch_to_reviewer", {input: "Review the report"}]
    when 2 then ["review_one_report", {query: "quarterly report"}]
    when 3
      return Phronomy::LLMAdapter::Response.new(content: "review ready", finish_reason: :stop)
    when 4
      return Phronomy::LLMAdapter::Response.new(content: "report ready", finish_reason: :stop)
    else
      raise "Unexpected repeated Provider work"
    end
    Phronomy::LLMAdapter::Response.new(tool_calls: [
      Phronomy::Tool::CallRequest.new(id: "call-#{@calls}", name: name, arguments: arguments)
    ], finish_reason: :tool_calls)
  end
end

def build_report_service
  G3gReviewTool.effects = []
  adapter = G3gReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  approvals = Queue.new
  parent = G3gReportParent.create(agent_id: "child-execution-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
  [adapter, stores, approvals, parent]
end
```

### Equivalent complete normal functions

The complete normal function is unchanged. This comparison promises equivalence for the ordinary successful path: the same request, approval policy, child effect, outputs, persisted statuses and final pair release. It does not promise equivalent handling of an injected ambiguous dispatch save.

For example, both executions read `quarterly report` once through the approved child, use four Provider responses, complete both saved executions and release the local parent/child pair. They preserve durable history under the existing retention policy.

<table>
<thead><tr><th>Before: applied G3f baseline</th><th>After: G3g candidate</th></tr></thead>
<tbody><tr><td>
<!-- example: normal-before -->
<pre><code># The public approval request supplies the exact child identity.
def run_report
  adapter, stores, approvals, parent = build_report_service
  parent_id = &quot;child-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: &quot;Prepare the report&quot;)
  request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent has its saved coordination wait for this approval-driven child.
  end
  child = Phronomy::Agent::Base.live_for_execution(request.execution_id)
  child_result = child.approve_async(request.execution_id,
    approval_request_id: request.id, approved: true).wait_result(timeout: 5)
  parent_result = parent.resume(parent_id)
  released = parent.unload_with_completed_child!(parent_id, execution_id: request.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3gReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision }
  }
end</code></pre>
</td><td>
<!-- example: normal-after -->
<pre><code># The public approval request supplies the exact child identity.
def run_report
  adapter, stores, approvals, parent = build_report_service
  parent_id = &quot;child-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: &quot;Prepare the report&quot;)
  request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent has its saved coordination wait for this approval-driven child.
  end
  child = Phronomy::Agent::Base.live_for_execution(request.execution_id)
  child_result = child.approve_async(request.execution_id,
    approval_request_id: request.id, approved: true).wait_result(timeout: 5)
  parent_result = parent.resume(parent_id)
  released = parent.unload_with_completed_child!(parent_id, execution_id: request.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3gReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision }
  }
end</code></pre>
</td></tr></tbody>
</table>

### Complete uncertain-save application

The fault-path adaptation handles retained dispatch responsibility on the original parent, then returns to the same report and approval policy. Its helper makes at most one reconciliation and one policy-authorized captured-write retry per observed failure. Unresolved recovery returns the parent and capability to the host; it does not loop, invoke again or release the unresolved owner.

For example, recovering the parent's Tool prerequisite leads to the original reviewer's approval request. Recovering the Provider prerequisite after the child has completed leads to the final parent report. A `recovery_pending` result is a host responsibility to retain and observe later, not a completed report.

The following complete helper and function share the service above. The injected `fault` callable is a test dependency defined below; it is not an application persistence or recovery API. This helper is exercised for captured native Provider/Tool prerequisites and does not generalize `child_approval_wait` to every rehydration-required error in an arbitrary application.

<!-- example: recovery-helper -->
```ruby
# Reconciliation reads evidence. Retrying a confirmed pre-state is a separate,
# explicit application policy; unresolved work keeps its original owner alive.
def recover_parent_dispatch(parent:, recovery:, retry_confirmed_pre: false)
  receipt = parent.reconcile_dispatch(recovery: recovery)
  if retry_confirmed_pre && receipt.outcome == :confirmed_pre
    receipt = parent.retry_dispatch(recovery: recovery)
  end
  if receipt.resolved?
    {state: :resumed, task: receipt.execution_task, receipt: receipt}.freeze
  else
    {state: :recovery_pending, parent: parent, recovery: recovery, receipt: receipt}.freeze
  end
end

# The resumed task may finish, fail, or reach this example's child approval wait.
# The earlier observation remains failed; it is never reused as the continuation.
def await_parent(parent:, task:, retry_confirmed_pre:, recoveries:)
  {state: :completed, result: task.wait_result(timeout: 5)}
rescue Phronomy::ExecutionRehydrationRequiredError
  {state: :child_approval_wait}
rescue Phronomy::Agent::DispatchRecoveryError => original_failure
  pending = parent.pending_dispatch_recovery(execution_id: original_failure.recovery.execution_id)
  raise "The exact parent recovery owner was not retained" unless pending.equal?(original_failure.recovery)
  observed = recover_parent_dispatch(parent: parent, recovery: pending,
    retry_confirmed_pre: retry_confirmed_pre)
  return observed if observed.fetch(:state) == :recovery_pending
  begin
    task.wait_result(timeout: 5)
    raise "The earlier failed observation reopened"
  rescue Phronomy::Agent::DispatchRecoveryError => repeated
    raise "The earlier failure changed" unless repeated.equal?(original_failure)
  end
  recoveries << {outcome: observed.fetch(:receipt).outcome, original_closed: true,
                 continuation_state: observed.fetch(:receipt).continuation_state}
  begin
    {state: :completed, result: observed.fetch(:task).wait_result(timeout: 5)}
  rescue Phronomy::ExecutionRehydrationRequiredError
    {state: :child_approval_wait}
  end
end
```

<!-- example: recovery-function -->
```ruby
# Both dispatch boundaries use the same original parent and retained capability.
# Approval is still an application decision, supplied exactly once for the child.
def run_report_with_recovery(fault:, retry_confirmed_pre: false)
  adapter, stores, approvals, parent = build_report_service
  parent_id = "child-report-execution"
  fault.call(stores.agent, parent_id)
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  recoveries = []
  original = parent.start_hosted(reservation: reservation, input: "Prepare the report")
  first = await_parent(parent: parent, task: original,
    retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  if first.fetch(:state) == :recovery_pending
    return first.merge(stores: stores, parent_execution_id: parent_id).freeze
  end
  raise "Expected the report child's approval wait" unless first.fetch(:state) == :child_approval_wait
  request = Timeout.timeout(5) { approvals.pop }
  child = Phronomy::Agent::Base.live_for_execution(request.execution_id)
  child_result = child.approve_async(request.execution_id,
    approval_request_id: request.id, approved: true).wait_result(timeout: 5)
  resumed = parent.resume_async(parent_id)
  last = await_parent(parent: parent, task: resumed,
    retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  if last.fetch(:state) == :recovery_pending
    return last.merge(stores: stores, child: child, parent_execution_id: parent_id).freeze
  end
  raise "Expected the completed report" unless last.fetch(:state) == :completed
  parent_result = last.fetch(:result)
  released = parent.unload_with_completed_child!(parent_id, execution_id: request.execution_id)
  {
    state: :observed, child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3gReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).status },
    history_holds: [parent.agent_id, child.agent_id].map { |id| stores.agent.retained_references(agent_id: id).size },
    recoveries: recoveries
  }
end
```

| Observable behavior | G3f baseline | G3g intentional change |
| --- | --- | --- |
| Ordinary successful report | Four Provider calls, one Tool effect, same child/parent outputs and completed statuses, pair release | Equivalent complete normal function and behavior |
| Parent captured prerequisite loses its response and immediate readback | Characterized cases leave the parent admitted and the observer times out without pending dispatch recovery | The original parent exposes its retained capability; read-only reconciliation or explicit captured-write retry can authorize the same continuation |
| Original failed observation | Ends without becoming a new successful observation | Remains closed; the returned execution task is a distinct observation of the same job |
| Unresolved native authority | No new acceptance claim | No new dispatch, replacement child or request; host retains the parent/capability |
| Approval and cleanup policy | Host decides approval and releases the exact completed pair | Preserved; recovery does not auto-approve or release unresolved work |

The application benefit is a supported public recovery branch with exact framework-owned proof and continuation custody. Phronomy removes the need for application code to interpret extension JSON, reconstruct reservations or devise persistence replay. Approval, observation timing, retry permission, unresolved-owner retention and final cleanup remain explicit application responsibilities.

For example, the report host can choose `retry_confirmed_pre: false`, retain the `recovery_pending` value, and later call the same helper after an operator decision. It must not rerun `run_report_with_recovery` for that unresolved request.

### Shared driver and fault fixture

The normal driver ends its Runtime only after the complete normal flow. The fault fixture is optional validation infrastructure that loses a selected parent dispatch save response and its immediate readback; it deliberately instruments internal boundaries and is separate from the public application source.

For example, `parent_reply_loss(kind: :tool, mode: :pre)` rolls back the parent Tool prerequisite, whereas `mode: :post` preserves its committed records. The same `run_report_with_recovery` function is exercised for Provider and Tool boundaries. A long-running host keeps an unresolved Runtime alive instead of copying the one-shot normal driver's `ensure` into a pending recovery path.

<!-- example: shared-driver -->
```ruby
# A long-running service retains recovery_pending and its Runtime for a later
# operator decision. This one-shot driver runs only the normal completed flow.
if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(run_report)
  ensure
    Phronomy.reset_runtime!
  end
end
```

<details>
<summary>Complete optional response-loss fixture used by validation</summary>

<!-- example: fault-fixture -->
```ruby
# Optional response-loss fixture; the application below uses public APIs only.
module G3gChangeFaultScope
  def perform
    fault = coordinator.instance_variable_get(:@g3g_parent_fault)
    previous = Thread.current[:g3g_parent_fault]
    selected = fault && execution_id == fault.fetch(:execution_id) && kind == :dispatch &&
      @updated&.phase == ((fault.fetch(:kind) == :tool) ? :dispatching_tools : :calling_llm)
    Thread.current[:g3g_parent_fault] = selected ? fault : nil
    super
  ensure
    Thread.current[:g3g_parent_fault] = previous
  end
end

module G3gAtomicFault
  def atomic(*args, &transaction)
    fault = Thread.current[:g3g_parent_fault]
    return super unless fault
    if fault[:readback]
      fault[:readback] = false
      raise IOError, "Immediate parent readback unavailable"
    end
    return super unless fault[:armed]
    fault[:armed] = false
    fault[:attempts] += 1
    if fault.fetch(:mode) == :pre
      super do |scope|
        transaction.call(scope)
        fault[:readback] = true
        raise IOError, "Parent dispatch transaction rolled back; response lost"
      end
    else
      super
      fault[:readback] = true
      raise IOError, "Parent dispatch transaction committed; response lost"
    end
  end
end

Phronomy::Agent::ExecutionChange.prepend(G3gChangeFaultScope)

def parent_reply_loss(kind:, mode:)
  raise ArgumentError, "Unsupported parent dispatch boundary" unless %i[provider tool].include?(kind)
  raise ArgumentError, "Unsupported save outcome" unless %i[pre post].include?(mode)
  lambda do |store, execution_id|
    store.coordinator.singleton_class.prepend(G3gAtomicFault)
    store.coordinator.instance_variable_set(:@g3g_parent_fault,
      {kind: kind, mode: mode, execution_id: execution_id, armed: true, readback: false, attempts: 0})
  end
end
```

</details>

The recorded normal baseline and candidate reports are identical. All four candidate Provider/Tool pre/post fault flows complete with four Provider calls, one Tool effect, closed original observations, both executions completed, successful pair release and retained history holds. Both explicit no-retry pre-state flows remain `confirmed_pre` with the original owner retained. The four baseline fault flows time out without a pending dispatch capability, and their incomplete process cleanup preserves the retained responsibility. The validation driver selects the baseline or candidate source, applies the fixture, runs the complete source and records loaded Ruby source locations and observed effects. The delivery includes those reports separately; the fixture's expected JSON or syntax check alone is not behavioral equivalence evidence.

For example, the baseline source must resolve into its isolated G3f checkout and the candidate source into the changed checkout. A successful candidate report is not evidence of baseline behavior unless both actual runs and their loaded-source provenance are recorded.


## Apply recovery policy to the original parent

The existing Agent dispatch APIs address the exact live owner and its captured operation. Every asynchronous observation is independent; a later receipt does not reopen the failed original invocation or hosted observation. Applications retain their parent and capability while unresolved, choose whether to retry captured persistence, and observe the returned execution task after continuation handoff.

For example, the report host receives a parent `DispatchRecoveryError`, reconciles once, and explicitly retries only a confirmed pre-state according to its own policy. A Tool continuation reaches the same child's approval boundary; a Provider continuation after child completion reaches the parent's final report. Neither path starts a replacement report request.

| Public surface | Native parent behavior |
| --- | --- |
| `pending_dispatch_recovery(execution_id:)` | Existing local lookup on the original parent; no Store access or replacement owner |
| `reconcile_dispatch[_async](recovery:)` | Read and classify captured parent evidence; freshly check native child authority before first continuation; no persistence retry |
| `retry_dispatch[_async](recovery:)` | Explicit captured-write retry only for exact pre-state with native authority; known post-state is read-only |
| `DispatchRecoveryResult` | Existing saved-outcome, application, continuation and physical-completion fields; a continuation error does not revoke known committed history |
| `execution_task` | Fresh observation of the same parent's continued execution after handoff; its later result/error is separate from save proof |
| Existing execution cancellation | Authoritative control of the execution; cancelling a recovery observation alone does not cancel the retained operation |

The ordinary invocation, streaming and hosted-entry contracts remain distinct. A closed stream subscriber is not resumed by dispatch recovery, and a recovered execution task does not invent a hosted handle or another approval observer. Existing application approval listeners remain the source of the child's public identity.

For example, a report child that requests approval after a recovered Tool prerequisite is identified by its actual approval event. The application must not extract an internal child slot or guess an execution ID from error prose. The complete application comparison demonstrates the public route used by this increment.

## Assess compatibility and symmetry

The native extension uses the same dispatch capability and receipt as ordinary and correlated-child dispatch recovery. Different domain facts justify different proof adapters, while observation, retry naming and physical-work accounting remain shared. Actual-terminal and approval operations retain their own continuation and release semantics.

For example, resolving a parent dispatch barrier allows the same parent job to continue; it does not release that active parent's execution admission. Reusing terminal release behavior at this point would discard the responsibility that the recovered Provider or Tool still needs.

| Dimension | Ordinary/participant-free child dispatch | Native parent dispatch | Terminal or approval peers |
| --- | --- | --- | --- |
| Names and arguments | Existing reconcile/retry methods with `recovery:` | Adopt the same methods and defaults | Preserve operation-specific names and policy; no universal Job API |
| Public values | Existing immutable capability and receipt | Adopt the same shape | Retain distinct result meanings and continuation/release rules |
| Saved proof | Complete Agent footprint, including opaque child correlation where present | Add native parent plan/evidence without teaching Agent the native schema | Keep each operation's domain write set |
| Current authority | Original owner/session and supported child checks | Add exact affected-child authority under ordered guards | Approval authorizes protected work; actual terminal establishes final custody/release |
| Sync/async and invoke/stream | Existing paired observation methods and closed-observer rules | Adopt the same rules | Preserve existing host-thread restrictions and observation independence |
| Creation and recovery | No replacement Agent or new invocation | No replacement parent or child reservation | No capability-based process takeover |
| Cleanup | Resolve barrier custody; continuing job remains owned | Same, with native history holds unchanged | Terminal may release only when its own conditions hold |

Decision: adopt the existing public dispatch API and shared retained-operation machinery; add a private native persistence/authority adapter; defer Handoff, generic custom participants and nonterminal/final-operation policy. Reject repeating `participant.commit`, constructing new child identities, using known post-state as unconditional permission to continue, or introducing a native-only convenience recovery facade.

For example, a convenience method that invoked the parent again after a timeout would appear to shorten application code while starting a different execution. The retained capability already expresses the required same-owner relationship without that behavioral change.

## Bound acceptance and remaining work

Acceptance distinguishes demonstrated baseline behavior, the candidate's new native dispatch behavior and remaining operation-specific work. The finite completion groups stay unchanged. A passing dispatch matrix does not certify native true-final, coordination-wait, Handoff, participant approval, crash recovery or every durable backend.

For example, four baseline native failed-child terminal cases already preserve acknowledgement atomicity: a pre-state can resume to failed without repeating the child effect, and a post-state is already failed. Two Handoff post-state probes also recover through exact Target continuation or result observation. Those existing paths should be preserved, not described as uniformly broken to justify dispatch changes.

| Acceptance boundary | Required observable result |
| --- | --- |
| Native Provider/Tool pre/post uncertainty | Recover the original parent through its existing public capability; preserve Provider/Tool effect counts and exact child identities |
| Unavailable or conflicting evidence | Retain responsibility and block continuation without a replacement request or arbitrary writes |
| Exact pre-state retry | Save only captured native content/hold/execution effects under ordered guards; do not repeat preparation, Policy or participant commit |
| Known-post reconciliation/retry | Preserve committed history; freshly check child authority; do not rewrite post-state or dispatch twice |
| Child authority changes | Reject active, suspended, replaced, partially absent or unheld histories according to the finite authority table |
| Observation and physical-work races | Keep old observations closed; prevent stale/duplicate application and release while physical work remains |
| Cancellation | Respect authoritative cancellation before external continuation; do not turn recovered permission into uncancelled work |
| Ordinary application and final lifetime | Preserve public report behavior, exact approval identity and existing pair-release/retained-history policy |
| Model and architecture | Check the finite safety/conditional-progress model and its mutations; preserve Contract ownership and dependency directions |

At the G3g boundary, native true-final and coordination-wait disposition required one coherent follow-up design around saved facts, public observation closure/publication and owner release. Native/Handoff own approval decisions and wait establishment were reachable separate writes. G3h addresses the supported native final/wait and own approval portion through its [outcome contract](native-parent-outcome-recovery.md). Handoff transfer still needs historical lineage and current-routing authority; generic custom participants still require explicit supported capability and unsupported disposition. These remain bounded checklist items within the existing completion groups.

For example, an active Handoff Agent can use an ordinary approval-requiring Tool. Its approval-decision fallback is not automatically protected by the dispatch plan or the synchronous participant readback. Leaving that row explicit prevents a narrower successful dispatch increment from becoming an unsupported whole-system coverage claim.

The finite [native parent dispatch model](../../spec/models/native_parent_dispatch_recovery/README.md) separates parent-owner, child-authority and client-observer state views and checks safety plus conditional progress. Its deliberate mutations and missing-premise cases must produce their specified counterexamples; those expected detections are not unresolved violations of the positive model. The delivery separately records exact source provenance, baseline characterization, Runtime faults, complete application reports and the English-file gate. Model checking is not a refinement proof of all Ruby behavior, and the in-memory fault fixture does not establish remote transaction settlement or external exactly-once effects.

For example, a model mutation that removes the current-child check must violate continuation safety. The Runtime acceptance must independently reproduce that changed child state and demonstrate that no protected Provider or Tool call was admitted.
