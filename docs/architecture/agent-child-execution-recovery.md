# Original-owner recovery for correlated child execution

An accepted child owns the preparation and completion of its execution even when a coordinating parent reserved that execution. The child must retain an uncertain dispatch barrier or terminal save until the same owner can establish and apply the saved outcome. The parent separately owns result import and its own continuation. G3e extends the existing retained Agent operations to correlated children without adding another manager or parent recovery facade.

For example, a report parent starts a reviewer child. The child asks permission to read one report. After the host approves, the child either loses its Tool-dispatch save response or loses the response that records the completed review. Recovery must use the already accepted child and original work, while keeping the parent's independent import and release rules intact.

Baseline: applied G3d `ae2070e36687f376754128deea1a41c69f416a0c`, tree `4b786f3359f481263c598e7ac66a50082b4bf29f`. This document describes the G3e implementation candidate. Contract concept v55 and foundation v48 remain current; exact candidate identity and final validation are in the delivery evidence.

## Keep the child obligation separate from parent progress

The child's captured proposal includes its execution identity and opaque reservation correlation. Dispatch proof permits only the original next action; terminal proof describes an already computed outcome. Neither proof updates the parent's child slot or decides whether that parent has imported a result.

For example, a parent can read a committed child terminal result while the original child's terminal recovery is still retained. That read does not release the child's local owner. Conversely, a child can finish recovery while the parent remains at its coordination wait and needs an explicit `resume` under the parent's existing protocol.

| Responsibility | Owner and evidence | What it does not establish |
| --- | --- | --- |
| Accepted child identity | Original Agent incarnation, execution, session and immutable reservation correlation | A new parent instruction or permission to create another child |
| Saved dispatch barrier | Complete captured child pre/post footprint; the original prepared input and continuation | Admission or completion of an external Provider/Tool request |
| Fresh dispatch continuation | Original unconsumed continuation right plus a current matching child snapshot | A distributed fence through a later external call |
| Saved actual terminal outcome | Complete child root/execution/journal/content/cancellation evidence | Parent import or arbitrary participant transaction outcome |
| Parent result import | Coordinating domain's existing exact child slot and guarded import protocol | Physical completion of child recovery work |
| Peer release | Existing retention and matching completed-pair checks | Permission inferred from a failed caller or a terminal row alone |

A saved failed or cancelled child does not imply successful parent import. Under the native parent's default `on_error: :raise` policy, the parent can fail while its child slot remains `imported: false`; history retentions can therefore continue to reject completed-pair unload even after both local execution admissions are released. This is an existing coordinating-domain error/import-policy obligation, not permission for child recovery to drop those holds.

The child treats reservation data as opaque. It does not import native parent types, interpret child slots, freeze a parent revision or require unchanged parent retention history to finish an already accepted child obligation. Participant-owned changes and execution extensions remain excluded. Retentions continue to govern domain release, separately from the child-only saved-state comparison.

## Revalidate before new dispatch admission

A previously confirmed dispatch post-state remains historical knowledge of a saved barrier. A correlated child that has not yet consumed its original continuation right must establish that the current child footprint still matches before granting that right. Later parent progress does not replace that child check.

For example, if the child reservation, revision or cancellation evidence changes after a saved post-state was observed but before continuation admission succeeds, a later receipt can still say `confirmed_post` while continuation remains pending. A missing read cannot authorize Tool work. Once admission was already authorized or is uncertain, another observation cannot grant a second admission.

This is a guarded snapshot under the selected Store, not a distributed lock held through external dispatch. The existing cooperative-writer, authoritative-read and cancellation assumptions remain. A later cancellation may leave a retained obligation when its captured preconditions no longer match; this increment does not invent an administrative resolution for every stopped or externally modified owner.

## Recover through the original child API

A recovery capability belongs to one exact child incarnation and retained operation. Existing local lookup, read-only reconciliation and explicit persistence retry are sufficient; the parent does not reconstruct or adopt the child's capability.

For example, an approval-driven service receives `request.execution_id` in the public ApprovalRequest and resolves its original child with `Agent::Base.live_for_execution`. A direct child observation can raise a typed recovery error. When a coordinating observer hides that error, the host can use the same known identity to query the child's pending recovery instead.

| Public contract | Dispatch boundary | Actual terminal boundary |
| --- | --- | --- |
| Local pending lookup | `pending_dispatch_recovery(execution_id:)` | `pending_terminal_recovery(execution_id:)` |
| Read-only reconciliation | `reconcile_dispatch[_async](recovery:)` | `reconcile_terminal[_async](recovery:)` |
| Explicit captured-write retry | `retry_dispatch[_async](recovery:)` | `retry_terminal[_async](recovery:)` |
| Mechanism-proven first submission retry | No generic replay of preparation | Existing `retry_terminal_submission[_async]`, only after positively proven non-admission |
| Completion observation | Independent `execution_task` after resolved continuation handoff | Immutable terminal `execution` after saved post-state |
| Pending result | Retain child, capability, Runtime and claim | Same requirement |
| Parent continuation | Existing parent protocol | Existing parent protocol |

The selected parent profiles are native Orchestrator children and Team coordinator/worker children. Their opaque reservation values use the same child protocol; the parent adapters keep their own import and cleanup rules. Team forwards typed child recovery errors unchanged when they reach the caller, so those errors supply the child identity and capability directly. A Team can also complete from a saved terminal child result while child-local recovery still blocks cleanup; a later existing Team resume can finish that cleanup after child reconciliation. These cases do not establish arbitrary participant or Handoff recovery.

Synchronous variants retain host-thread waiting and EventLoop reentrancy checks. Asynchronous variants retain independent observations. Cancelling a recovery observation does not cancel canonical work. Dispatch receipt physical completion concerns its preparation/recovery workers, not the later Tool or entire job. Terminal release remains conditional on the original operation's physical quiescence. Resolved capabilities preserve historical receipts without reopening failed observations or replaying work.

Terminal recovery preserves the child's existing `ReservedExecution` reservation value in its returned execution observation; this is consistency of an existing field, not a new result shape.

A native coordinating task can wrap a child operation error in `ExecutionRehydrationRequiredError`. An exact execution observer can instead fulfill from a committed terminal record even after an internal save error. Therefore, not every original observer fails, and parent success is not a child-cleanup acknowledgement. After a successful exact-child or parent observation, a host holding the original child reference and its known execution identity must still check `child.pending_terminal_recovery(execution_id: child_execution_id)` before claiming local recovery cleanup. If it returns a capability, use `child.reconcile_terminal(recovery: recovery)` and, only by explicit policy, `child.retry_terminal(recovery: recovery)` for confirmed pre-state; require confirmed post, applied state and released ownership before completing that cleanup. The ordinary domain unload/import checks still apply. This management instruction is supported by the separate native and Team terminal-post acceptance; the seven Runtime application cases below deliberately use a direct approval observation and do not claim general successful-observer discovery coverage.

General child discovery from an arbitrary parent error is not added; the example below deliberately uses a public approval request to obtain the identity.

## Preserve the ordinary report application

The ordinary report preserves its input, approval policy, one protected Tool effect, output, parent import and completed-pair release. Extending recovery eligibility requires no application source change on this ordinary path.

For example, both source columns below run four deterministic Provider calls, read the quarterly report exactly once, save the child and parent as completed, and release the matching pair. They use the same real Runtime, in-memory persistence and offline Provider. The response-loss fixture is inactive for this comparison.

### Shared application setup

The shared setup defines the parent and reviewer roles, the approval Tool, the offline Provider and the application event queue. The queue conveys only the public approval request; it does not expose native slot internals.

For example, the parent Provider requests its reviewer, the reviewer requests one report read, and the two remaining Provider responses complete the child and parent outputs. The recorded Tool effects detect accidental repeated business work.

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"
require "timeout"

class G3eReviewTool < Phronomy::Tool::Base
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

class G3eReviewAgent < Phronomy::Agent::Base
  agent_definition id: "child-execution-reviewer", version: 1
  model "offline-model"
  tools G3eReviewTool => nil
end

class G3eReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "child-execution-parent", version: 1
  model "offline-model"
  subagent :reviewer, G3eReviewAgent
end

class G3eReportAdapter < Phronomy::LLMAdapter::Base
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
  G3eReviewTool.effects = []
  adapter = G3eReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  approvals = Queue.new
  parent = G3eReportParent.create(agent_id: "child-execution-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
  [adapter, stores, approvals, parent]
end
```

### Equivalent before and after source

The normal function holds the same parent and child identities and follows the same approval and import policy on the baseline and candidate. Each column is the complete function, with shared setup and the driver shown separately.

For example, the public approval request supplies the child identity before either version approves the read. The parent has already reached its saved coordination wait in this particular application, so both versions explicitly resume it after the child's ordinary completion.

<table class="source-comparison">
<thead><tr><th>Applied G3d baseline</th><th>G3e candidate</th></tr></thead>
<tbody><tr><td valign="top">
<!-- example: normal-before --><pre><code># The public approval request supplies the exact child identity.
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
    tool_effects: G3eReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision }
  }
end</code></pre>
</td><td valign="top">
<!-- example: normal-after --><pre><code># The public approval request supplies the exact child identity.
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
    tool_effects: G3eReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision }
  }
end</code></pre>
</td></tr></tbody></table>

### Ordinary executable driver

The driver owns the demonstration Runtime for the completed ordinary example. A long-running service handling an unresolved recovery result must instead retain its original Runtime and external claim until its explicit recovery policy resolves that obligation.

For example, running this file without fault injection produces the complete report and then resets its now-finished Runtime. The recovery function below returns retained context when unresolved; it must not be treated as a fresh invocation request.

<!-- example: shared-driver -->
```ruby
# This driver runs the ordinary completed example. A long-running service keeps
# a recovery_pending result and its live Runtime for a later explicit decision.
if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(run_report)
  ensure
    Phronomy.reset_runtime!
  end
end
```

## Make save retry an explicit application decision

The application distinguishes reading saved evidence from retrying captured writes and distinguishes child completion from parent import. The recovery helper performs one reconciliation and at most one separately authorized captured-write retry. It returns the retained owner and capability when responsibility remains pending.

For example, a confirmed rollback of the Tool barrier leaves the report unread. With retry disabled, the host receives `recovery_pending`. A later explicit call with the same capability can retry the original save and execute the protected read once. A terminal rollback retains the already computed review rather than running the Tool again.

<!-- example: recovery-helper -->
```ruby
# Reconciliation reads evidence; write retry is a separate application choice.
def recover_child_boundary(child:, recovery:, retry_confirmed_pre: false)
  receipt = case recovery
  when Phronomy::Agent::DispatchRecovery
    observed = child.reconcile_dispatch(recovery: recovery)
    if retry_confirmed_pre && observed.outcome == :confirmed_pre
      observed = child.retry_dispatch(recovery: recovery)
    end
    observed
  when Phronomy::Agent::TerminalRecovery
    observed = child.reconcile_terminal(recovery: recovery)
    if retry_confirmed_pre && observed.outcome == :confirmed_pre
      observed = child.retry_terminal(recovery: recovery)
    end
    observed
  else
    raise ArgumentError, "Expected this child's dispatch or terminal capability"
  end
  result = if receipt.is_a?(Phronomy::Agent::DispatchRecoveryResult) && receipt.resolved?
    receipt.execution_task.wait_result(timeout: 5)
  elsif receipt.is_a?(Phronomy::Agent::TerminalRecoveryResult) &&
      receipt.outcome == :confirmed_post && receipt.application_state == :applied &&
      receipt.ownership_state == :released && receipt.execution
    receipt.execution.to_result
  end
  if result
    {state: :observed, result: result, receipt: receipt}.freeze
  else
    # The service must retain this owner, capability, Runtime and external claim.
    {state: :recovery_pending, child: child, recovery: recovery, receipt: receipt}.freeze
  end
end
```

### Complete response-loss example

The complete example keeps the same public child identity and makes the human approval exactly once. Its additional branches handle an uncertain child boundary and preserve the parent context when that boundary remains unresolved.

For example, after a lost terminal response, the helper can confirm the completed child and release its local recovery owner. This example's parent is still at its coordination wait, so it then resumes and imports the saved review. Other native parents may already have imported the result; that independent behavior does not change the child's recovery receipt.

<!-- example: recovery-example -->
```ruby
# The injected fault is optional test setup; approving remains a single action.
def run_report_with_recovery(fault:, retry_confirmed_pre: false)
  adapter, stores, approvals, parent = build_report_service
  parent_id = "child-report-execution"
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: "Prepare the report")
  request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # This example deliberately begins at the same coordination wait as normal.
  end
  child = Phronomy::Agent::Base.live_for_execution(request.execution_id)
  fault.call(stores.agent, request.execution_id)
  decision = child.approve_async(request.execution_id,
    approval_request_id: request.id, approved: true)
  failure = begin
    decision.wait_result(timeout: 5)
    raise "The injected child save uncertainty was not observed"
  rescue Phronomy::Agent::DispatchRecoveryError, Phronomy::Agent::TerminalRecoveryError => error
    error
  end
  observed = recover_child_boundary(child: child, recovery: failure.recovery,
    retry_confirmed_pre: retry_confirmed_pre)
  if observed.fetch(:state) == :recovery_pending
    return observed.merge(parent: parent, parent_execution_id: parent_id, stores: stores).freeze
  end
  child_result = observed.fetch(:result)
  # This particular parent is at a coordination wait. Other native parents may
  # already have imported a saved terminal result; their status is independent.
  parent_result = parent.resume(parent_id)
  released = parent.unload_with_completed_child!(parent_id, execution_id: request.execution_id)
  begin
    decision.wait_result(timeout: 5)
    raise "The original failed observation reopened"
  rescue Phronomy::Agent::DispatchRecoveryError, Phronomy::Agent::TerminalRecoveryError => original_failure
    raise "The original failure changed" unless original_failure.equal?(failure)
  end
  {
    state: :observed, child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    tool_effects: G3eReviewTool.effects, provider_calls: adapter.calls, released: released,
    statuses: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision },
    recovery_outcome: observed.fetch(:receipt).outcome
  }
end
```

### Optional deterministic failure fixture

The fixture changes only the observation of an actual child persistence transaction and its immediate readback. It scopes the fault to one known child and boundary, then leaves later explicit recovery reads and retries available. It is test setup, not application retry policy or a public framework extension.

For example, `child_reply_loss(kind: :dispatch, mode: :pre)` executes the selected atomic body once and rolls it back before losing the response. The `post` variant commits before losing the response. `run_report_with_recovery(fault: child_reply_loss(kind: :terminal, mode: :post), retry_confirmed_pre: false)` exercises terminal confirmation without another save.

<!-- example: fault-fixture -->
```ruby
# Optional response-loss fixture; application recovery below uses public APIs.
# The original atomic body runs once, and the immediate readback is unavailable.
module G3eChangeFaultScope
  def perform
    fault = coordinator.instance_variable_get(:@g3e_child_fault)
    previous = Thread.current[:g3e_child_fault]
    selected = fault && execution_id == fault.fetch(:execution_id) && kind == fault.fetch(:kind)
    Thread.current[:g3e_child_fault] = selected ? fault : nil
    super
  ensure
    Thread.current[:g3e_child_fault] = previous
  end
end

module G3eAtomicFault
  def atomic(*args, &transaction)
    fault = Thread.current[:g3e_child_fault]
    return super unless fault
    if fault[:readback]
      fault[:readback] = false
      raise IOError, "Immediate child readback unavailable"
    end
    return super unless fault[:armed]
    fault[:armed] = false
    if fault.fetch(:mode) == :pre
      super do |scope|
        transaction.call(scope)
        fault[:readback] = true
        raise IOError, "Child transaction rolled back; response lost"
      end
    else
      super
      fault[:readback] = true
      raise IOError, "Child transaction committed; response lost"
    end
  end
end

Phronomy::Agent::ExecutionChange.prepend(G3eChangeFaultScope)

def child_reply_loss(kind:, mode:)
  raise ArgumentError, "Unsupported child boundary" unless %i[dispatch terminal].include?(kind)
  raise ArgumentError, "Unsupported save outcome" unless %i[pre post].include?(mode)
  lambda do |store, execution_id|
    store.coordinator.singleton_class.prepend(G3eAtomicFault)
    store.coordinator.instance_variable_set(:@g3e_child_fault,
      {kind: kind, mode: mode, execution_id: execution_id, armed: true, readback: false})
  end
end
```

## Identify the behavior improvement and its limits

G3e adds retained recovery for supported correlated child boundaries while preserving ordinary behavior and existing public value shapes. It removes the need to discard the original child and reconstruct work merely because a save response was lost. The application still chooses retry timing, holds its external claim and coordinates parent progression.

For example, a failed original child approval observation stays failed after its later dispatch recovery succeeds. The application receives a separate continuing execution observation and can finish the original report without approving or invoking it again. A pending receipt is not converted into success to simplify application source.

| Case | Applied G3d baseline | G3e candidate |
| --- | --- | --- |
| Ordinary correlated child | Existing reserved child execution and parent import | Same application contract |
| Follow-up child dispatch with unknown save outcome | No retained dispatch capability on the reserved path; parent can remain pending | Original child retains the proposal and exposes existing dispatch recovery |
| Actual child terminal with unknown pre-state | Alternate error path can relinquish local child ownership without retained terminal recovery | Retained child obligation and explicit guarded terminal save retry |
| Saved child terminal with lost response | A parent may read/import the terminal result independently | Parent observation remains independent; retained child recovery still requires local application/release |
| Later child state conflicts with cached dispatch proof | No correlated retained continuation protocol | Historical post knowledge is preserved but new admission is withheld |
| Parent participant save or Handoff uncertainty | Separate existing contract | Still a separate residual obligation |

## Preserve symmetry and responsibility boundaries

The supported child path reuses the same domain operations as an ordinary Agent. Dispatch and terminal retain different completion semantics because one permits future work and the other records finished work. Parent import remains a coordinating-domain decision, rather than an extra flag on either child receipt.

For example, giving `DispatchRecoveryResult` a terminal-style `released` verdict would imply a running child no longer needs ownership. Giving terminal recovery a new execution task would obscure its already-computed result. The existing shapes preserve these distinctions without new methods or RBS fields.

| Comparison | Decision and reason |
| --- | --- |
| Ordinary versus correlated child operation names | Adopt unchanged names and argument defaults |
| Sync versus async | Adopt existing pairs and reentrancy/observation rules |
| Dispatch versus terminal pre-state | Retain both obligations until explicit captured-write retry; neither starts a replacement request |
| Approval versus dispatch/terminal pre-state | Preserve approval's separate restored-wait meaning; no automatic repeated human decision |
| Parent result import versus child recovery | Keep separate existing owners and operations |
| New generic child-recovery manager or parent facade | Reject: existing child capability and domain methods are sufficient for the supported use case |
| Arbitrary child discovery from parent errors | Defer: not required for the named public-approval-request scenario and not implemented here |

## Validate the selected boundaries

Acceptance combines exact baseline comparisons, real Runtime fault cases and bounded model properties. Each category checks a different claim: application equivalence, concrete saved-state/ownership behavior, or the abstract protocol under explicit premises.

For example, the documented normal report must match on baseline and candidate, while each dispatch/terminal pre/post loss must preserve one Tool effect and complete only through the original child capability. A negative model that releases a pending owner or permits a second dispatch must produce its expected counterexample.

The separate Team fault matrix covers coordinator/worker roles across Provider, Tool and actual terminal pre/post uncertainty (12 cases); it does not repeat a Team coordinator or worker to reconstruct accepted child work. General Workflow regression is compatibility evidence, not a new reserved-child fault claim.

The documented application checks comprise seven Runtime cases (ordinary; dispatch and terminal pre/post; and two separately authorized retry decisions) plus one complete-source consistency check. Final measured results and source hashes are recorded in the delivery evidence. The standalone [dispatch](agent-dispatch-recovery.md), [terminal](agent-terminal-recovery.md), and [terminal submission](agent-terminal-submission-recovery.md) contracts continue to define common receipt, physical-completion and admission conditions.

The scope is follow-up dispatch preparation and actual success/failure/cancellation terminal saves on supported original live children. Initial reserved admission, initial preparation, establishing an approval/coordination wait, parent participant commits, Handoff, custom execution extensions, stopped-owner administration and selected durable-backend acceptance are not completed by this eligibility change. A successful approval-driven application is not exhaustive proof of all reserved ownership paths.
