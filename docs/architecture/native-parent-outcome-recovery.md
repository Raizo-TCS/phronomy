# Native parent final, wait and approval recovery

A native coordinating Agent owns its accepted execution even when the reply to a saved final outcome or wait is lost. Its native participant owns the child relationships and persistence effects that accompany that outcome. G3h retains those captured facts, applies them through the original live owner and exposes the saved kind explicitly. A saved wait and a finished job have different meanings.

For example, a report parent first waits for its review child, then waits for approval of its own publishing Tool, and finally completes the report. Any of those three saves can commit without a reply. Recovering the first or second save establishes the same wait; it does not publish the report, decide approval or manufacture a final execution result.

Baseline: applied G3g commit `44288e1239701bf16aa67854a48c830b7295e2d4`, tree `31193090f7305c82da780765f803b955742330c7`. This document describes the G3h implementation candidate. Contract concept v55 and foundation v48 remain the responsibility references. Exact source identity, Runtime results, complete application comparison and model results belong to the delivery evidence. The preceding [native dispatch contract](native-parent-dispatch-recovery.md) remains the reference for Provider/Tool prerequisites.

## Represent the saved kind without changing terminal recovery

`TerminalRecovery` continues to mean recovery of an actually final execution. The new `OutcomeRecovery` family represents a native parent's final, coordination-wait or approval-wait save. Both use one private retained-operation mechanism, with a thin terminal specialization preserving the existing public types. Sharing physical-attempt and observer handling does not merge their domain meanings.

For example, a receipt with `saved_outcome: :coordination_wait` has no terminal `ExecutionObservation`. Its original child may still be suspended. Calling the wait a successful terminal result would cause the application to discard unfinished responsibility.

| Candidate | Decision | Reason |
| --- | --- | --- |
| Permit active/suspended executions in `TerminalRecoveryResult` | Withdraw | Would change the published meaning of terminal recovery |
| Add separate final, coordination-wait and approval-wait managers | Withdraw | Would duplicate retained-attempt, observation and submission mechanics |
| Add `OutcomeRecovery` with an explicit saved-kind receipt | Adopt | Distinguishes the domain outcomes while sharing the substantial owner mechanism |
| Return a new public execution task for every saved wait | Withdraw | Publishing a wait does not admit a new continuation; existing approval/resume APIs supply later observations |
| Add a universal Job API or participant recovery SPI | Defer | The native domain has bounded evidence; Handoff and arbitrary participants need their own authority and failure contracts |

`pending_outcome_recovery(execution_id:)` performs local lookup on the original Agent's existing Runtime registry. It performs no persistence I/O and creates no Runtime. Recovery methods require the exact issued `OutcomeRecovery`, operation profile and Agent incarnation; diagnostic identifiers cannot reconstruct this authority. A resolved capability can still return its receipt after pending lookup no longer finds it.

For example, after an invocation observer closes before receiving its recovery error, the host can retain the original parent and accepted execution identity, then find the still-retained obligation locally. Loading another parent with the same durable identifier is not an alternative recovery owner.

## Separate persistence facts, application and custody

The receipt records what was saved, whether the original owner applied it and whether that save-recovery responsibility was released. A captured proposal is not yet a saved fact. Only confirmed post-state has a saved kind, positive revision and its corresponding payload. Recovery release does not assert that an execution waiting on a child or human decision has finished.

For example, a confirmed approval wait can remain `application_state: :pending` after EventLoop publication is refused. Its request is evidence of the saved wait, not permission to bypass owner admission. Once applied, the same suspended execution retains its approval and cancellation ownership.

| Receipt reader | Contract |
| --- | --- |
| `recovery`, `agent_id`, `execution_id`, `recovery_id` | Original process-local capability and diagnostic identity |
| `outcome` | `confirmed_post`, `confirmed_pre`, `unresolved` or `unavailable` |
| `saved_outcome` | Nil unless confirmed post; then `terminal`, `coordination_wait` or `approval_wait` |
| `revision` | Exact positive saved execution revision only for confirmed post |
| `execution` | Exact terminal `ExecutionObservation` only for `saved_outcome: :terminal` |
| `approval_request` | Exact `ToolApprovalRequest` for this execution only for `saved_outcome: :approval_wait` |
| Coordination-wait payload | Neither terminal execution nor approval request; saved kind, identity and revision identify the fact |
| `application_state` | `pending` or `applied` by the original owner |
| `ownership_state` | `retained` or `released` for save-recovery custody; release requires applied confirmed post-state |
| `submission_state` | `not_admitted`, `admitted` or `unknown`; positive non-admission cannot coexist with captured pre/post proof |
| `error` | Recovery diagnostic; an actual final business failure is separately represented by `execution.error` |

The result is immutable and rejects contradictory combinations. It has no `resolved?` or `execution_task` convenience field. The application checks confirmed post, applied state and released recovery custody, then branches on `saved_outcome`. `OutcomeRecoveryError` preserves the immediate failure as `cause`, the original save failure as `original_error` and the retained capability as `recovery`.

For example, terminal recovery can succeed as a persistence operation while returning a saved failed execution. An application must inspect the terminal execution status/error before announcing a successful report; absence of a recovery error does not imply business success.

## Keep each observer closed and publish waits through their owner

An uncertain save can end the original invocation observation with `OutcomeRecoveryError` while the retained operation keeps responsibility. Reconciliation returns a fresh observation and never reopens that failed or cancelled task or replays its old stream/event listener. The recovered state is published through the original coordinator and registry on EventLoop after physical-work and identity checks.

For example, a recovered own approval wait returns its exact request directly in the new receipt. The application uses that request with existing `approve_async`; it must not wait for the old listener to emit the same approval event again. Ordinary successful wait establishment keeps its existing event behavior.

A recovered coordination wait installs the existing private coordination-wait reference, allowing the existing child approval and parent resume flow. A recovered own approval wait installs a private canonical wait observer and cancellation binding; the execution remains suspended and owned. Actual final publication uses the existing terminal application and release rules. Parent/child unloading and retained-history policy remain separate from resolving the save operation.

For example, after the child's exact approval finishes, `parent.resume_async(parent_id)` can move the same report process to its own publishing approval. The application still supplies that second decision explicitly and unloads the pair only after the final parent and child conditions hold.

## Bound readback, captured retry and first submission

The three outcome operations have different authority. Readback classifies saved facts and applies a confirmed result. Captured retry writes only an already complete immutable proposal. First-submission retry is available only after positive execution-mechanism evidence proves the initial save worker was not admitted and no handle or worker entry contradicts that fact.

For example, a rolled-back coordination-wait save can be retried with the exact captured extension, holds, content and execution records. It cannot rerun child reservation, select a new child, repeat provider input preparation, re-encode the result or call the original participant's business decision again.

| Public operation | Preparation/encoding | Persistence writes | Authority |
| --- | --- | --- | --- |
| `reconcile_outcome[_async](recovery:)` | No | None | Complete retained proof or a conclusive original worker result |
| `retry_outcome[_async](recovery:)` | No | Exact captured writes only | Full guarded pre-state and native relationship checks; known post is read-only |
| `retry_outcome_submission[_async](recovery:)` | First run only | First save | Positive non-admission, no returned handle and no worker entry |

The retry runs under the original Store identity, an outer atomic transaction and ordered affected Agent guards. It rechecks the complete parent proof and permitted native child relationship, replays bounded captured writes, then verifies complete post-state. Missing, conflicting or unavailable evidence grants no guessed rollback or replacement-owner permission.

For example, an exact unimported child may legally progress from active to suspended while the parent wait save is being recovered. That is compatible with saving the same wait. An imported or acknowledged child must retain the required terminal history, and a captured terminal acknowledgement must still match the exact child outcome.

| Boundary | Native child rule |
| --- | --- |
| Captured outcome pre-state retry | Existing unimported/unacknowledged child may remain exactly correlated and active, suspended or terminal, or be fully absent under the saved reservation |
| Imported child or captured terminal acknowledgement | Exact terminal identity, definition, native correlation, required hold and applicable acknowledgement |
| New or replaced child slot | Refused by the outcome plan, which preserves the existing slot set; native dispatch has its separate reservation proof |
| Confirmed saved outcome publication | Publishes captured history; does not itself admit Provider/Tool work or decide an approval |
| First dispatch or approval continuation | Fresh stricter authority for exact terminal or permitted fully absent/unimported/unacknowledged children |

An admitted worker that fails before producing complete outcome proof remains a retained, unavailable obligation. Neither absence of proof nor a stopped worker proves non-admission, and this increment does not add general encoder/preparation retry. That case remains explicit within completion group 1.

For example, if encoding raises after the worker accepted the command but before a full proposal exists, `retry_outcome_submission` cannot repeat it. Retaining the original owner is the supported safe disposition; automatic invocation retry would risk repeating earlier report effects.

## Recover the native parent's own approval decision

Saving an approval wait and saving its decision are separate operations. G3h extends existing `ApprovalRecovery` to a supported native parent's own Tool approval decision. It captures the complete parent pre/post proof and detached native authority, then checks current child authority under ordered guards before restoring or admitting the decision's continuation. It adds no approval-write retry API.

For example, the report parent has already imported its completed review child when the human approves publication. A lost decision response can leave a committed approval with a locally suspended parent. `reconcile_approval` can apply that same decision once and return its existing fresh execution observation without asking the human to decide again.

| Decision proof | Original-owner action |
| --- | --- |
| Confirmed pre-state with current authority | Restore the exact original request/wait; a subsequent approval is a separate explicit application decision |
| Confirmed post-state with current authority | Apply the captured approved/rejected decision once and resume the existing Tool batch |
| Confirmed post-state with changed authority | Preserve the historical committed decision but withhold continuation; no rewritten history or repeated decision |
| Unavailable or conflicting proof | Retain responsibility; do not guess approval or rejection |
| Complete captured decision before a failed first content write | Reconcile that full pre/post proof; no decision replay |
| Failure before complete proof with positive no-write-started evidence | After original physical completion, explicitly validate and restore only the same original wait through read-only recovery |

The proof captures decision bytes, reference and proposed records before the first content write, so a content-store failure does not unnecessarily discard available evidence. A pure capture/read failure preceding complete proof has the narrower no-write-started restoration route described above. This positive evidence is not a general retry permission for an admitted incomplete outcome proposal.

For example, after confirmed pre-state the report application may explicitly choose `approve_after_restore: true` and call `approve_async` again for the same request. Reconciliation itself never makes that fresh choice. After confirmed post-state it observes the already authorized continuation through `ApprovalRecoveryResult#execution_task`.

A Provider batch containing both an ordinary protected Tool and native child dispatch has an additional existing boundary. Exact G3g ordinary-flow characterization reaches a factual-resolution requirement after the child completes. G3h decision recovery preserves the captured decision and effect counts on that path, but does not make subsequent parent resume automatically finish it. The existing public factual-resolution operation completes the supported flow once the application supplies an independently known ordinary Tool result; recovery does not invent that result or silently resolve its subject.

For example, the complete application below uses sequential batches: child review finishes before the parent asks to publish. That path completes its five Provider calls and two Tool effects. Separate mixed-batch pre/post decision-loss acceptance uses `recovery_resolution_required` to obtain the exact execution revision and ordinary Tool subject, then calls `parent.resolve_async(execution_id, expected_execution_revision: revision, subject: subject, outcome: :succeeded, result: independently_known_result)`. Both cases finish with four Provider calls, one parent and one child effect, and eligible pair unload. The framework's native child slot resumes through its own contract; the application does not supply a fabricated framework Tool result. This verifies the explicit factual-resolution route, not automatic mixed-batch completion.

## Preserve public symmetry without merging operation meanings

Lookup, exact capability identity, fresh observation, host-thread waiting and original-owner custody follow the existing recovery conventions. Domain-specific results preserve the difference between a final fact, a saved wait and permission to start protected work. The public names and RBS signatures remain paired with their existing families.

For example, both terminal and outcome save retry are explicit captured-write operations, while approval recovery remains read-only. Adding a similarly named approval retry merely for surface symmetry would authorize a different decision and change the contract.

| Dimension | Terminal recovery | Outcome recovery | Approval recovery | Dispatch recovery |
| --- | --- | --- | --- | --- |
| Local lookup | `pending_terminal_recovery` | `pending_outcome_recovery` | `pending_approval_recovery` | `pending_dispatch_recovery` |
| Readback | `reconcile_terminal[_async]` | `reconcile_outcome[_async]` | `reconcile_approval[_async]` | `reconcile_dispatch[_async]` |
| Captured writes | `retry_terminal[_async]` | `retry_outcome[_async]` | None | `retry_dispatch[_async]` |
| Positive first-submission retry | `retry_terminal_submission[_async]` | `retry_outcome_submission[_async]` | Existing decision-owner policy | No new operation |
| Saved meaning | Actually final execution | Final, coordination wait or approval wait | One approval decision | Dispatch prerequisite |
| Later execution observation | Saved terminal `execution` | Terminal `execution` only; exact approval request for approval wait | Existing `execution_task` after resumed decision | Existing `execution_task` after continuation handoff |
| Resolved custody | Terminal save owner released | Save owner released; waiting job is not thereby final | Wait restored or continuation admitted | Continuing job remains owned |
| Observer policy | Earlier task stays closed | Same | Same | Same |
| Domain authority | Exact original owner and captured final proof | Native immutable outcome plan and bounded relationship proof | Fresh native child authority before decision application | Fresh native child authority before first continuation |

The substantial private physical-attempt machinery is shared by terminal and outcome owners. Native captured content/hold/execution plan and child-identity checks are shared within MultiAgent across dispatch, outcome and approval evidence where their meanings coincide. Agent consumes opaque native evidence; it does not interpret child-slot schema or call a concrete native coordinator class. These are bounded internal collaborators, not an external library or broad extension SPI.

For example, sharing an identity/correlation check avoids inconsistent replacement-child rules, while an outcome-specific flag still permits legal unfinished-child progress during wait-save retry. Forcing the stricter dispatch rule onto that retry would block a valid coordination wait.

## Preserve the complete report application

The complete application below creates one native parent, approves one review child, resumes the same parent, explicitly approves its own publishing Tool, observes the final report and unloads the eligible pair. The deterministic Provider adapter sends no network request; Agent, Store, Runtime, approval and ownership paths are real.

For example, the normal baseline report has child output `review ready`, parent output `report ready`, five Provider calls, one review effect and one publication effect. Both saved executions complete, with parent/child revisions 9/6 and one retained-history hold each. The candidate comparison uses the same complete normal source; fault recovery is a separate intentional behavior change, not an equivalence claim for ambiguous saves.

### Shared service and equivalent normal functions

The shared definitions contain both approval-requiring Tools, the exact parent/child definitions, a deterministic adapter and the public approval listener. Assemble them with one of the complete normal functions and the driver to reproduce the ordinary flow. The normal before/after columns intentionally contain identical source.

For example, the approval event's exact execution identity selects the child, while the second request must identify the parent. The application never parses native extension content to discover either approval target.

<!-- generated-application:shared-and-normal -->

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"
require "timeout"

require "phronomy"
require "json"
require "timeout"
class G3hReviewTool < Phronomy::Tool::Base
  tool_name "review_one_report"
  description "Review the approved report once"
  requires_approval true

  class << self
    attr_accessor :effects
  end

  def execute(query:)
    self.class.effects << query
    "reviewed #{query}"
  end
end

class G3hPublishTool < Phronomy::Tool::Base
  tool_name "publish_one_report"
  description "Publish the approved report once"
  requires_approval true

  class << self
    attr_accessor :effects
  end

  def execute(query:)
    self.class.effects << query
    "published #{query}"
  end
end

class G3hReviewAgent < Phronomy::Agent::Base
  agent_definition id: "native-outcome-reviewer", version: 1
  model "offline-model"
  tools G3hReviewTool => nil
end

class G3hReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "native-outcome-parent", version: 1
  model "offline-model"
  tools G3hPublishTool => nil
  subagent :reviewer, G3hReviewAgent
end

class G3hReportAdapter < Phronomy::LLMAdapter::Base
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
    when 4 then ["publish_one_report", {query: "quarterly report"}]
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

def build_report_service
  G3hReviewTool.effects = []
  G3hPublishTool.effects = []
  adapter = G3hReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  approvals = Queue.new
  parent = G3hReportParent.create(agent_id: "native-outcome-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
  [adapter, stores, approvals, parent]
end
```

<table>
<thead><tr><th>Before: applied G3g baseline</th><th>After: G3h candidate</th></tr></thead>
<tbody><tr><td>
<!-- example: normal-before -->
<pre><code># The exact approval request identifies which entity may accept the decision.
def run_report
  adapter, stores, approvals, parent = build_report_service
  parent_id = &quot;native-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: &quot;Prepare and publish the report&quot;)
  child_request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent waits for this approval-driven child.
  end
  child = Phronomy::Agent::Base.live_for_execution(child_request.execution_id)
  child_result = child.approve_async(child_request.execution_id,
    approval_request_id: child_request.id, approved: true).wait_result(timeout: 5)
  continued = parent.resume_async(parent_id)
  parent_request = Timeout.timeout(5) { approvals.pop }
  raise &quot;Expected the parent&#x27;s own approval&quot; unless parent_request.execution_id == parent_id
  begin
    continued.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent now waits for its own publication decision.
  end
  parent_result = parent.approve_async(parent_id,
    approval_request_id: parent_request.id, approved: true).wait_result(timeout: 5)
  released = parent.unload_with_completed_child!(parent_id, execution_id: child_request.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    review_effects: G3hReviewTool.effects, publication_effects: G3hPublishTool.effects,
    provider_calls: adapter.calls, released: released,
    statuses: [parent_id, child_request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, child_request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision },
    history_holds: [parent.agent_id, child.agent_id].map { |id| stores.agent.retained_references(agent_id: id).size }
  }
end</code></pre>
</td><td>
<!-- example: normal-after -->
<pre><code># The exact approval request identifies which entity may accept the decision.
def run_report
  adapter, stores, approvals, parent = build_report_service
  parent_id = &quot;native-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: &quot;Prepare and publish the report&quot;)
  child_request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent waits for this approval-driven child.
  end
  child = Phronomy::Agent::Base.live_for_execution(child_request.execution_id)
  child_result = child.approve_async(child_request.execution_id,
    approval_request_id: child_request.id, approved: true).wait_result(timeout: 5)
  continued = parent.resume_async(parent_id)
  parent_request = Timeout.timeout(5) { approvals.pop }
  raise &quot;Expected the parent&#x27;s own approval&quot; unless parent_request.execution_id == parent_id
  begin
    continued.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent now waits for its own publication decision.
  end
  parent_result = parent.approve_async(parent_id,
    approval_request_id: parent_request.id, approved: true).wait_result(timeout: 5)
  released = parent.unload_with_completed_child!(parent_id, execution_id: child_request.execution_id)
  {
    child_output: child_result.fetch(:output), parent_output: parent_result.fetch(:output),
    review_effects: G3hReviewTool.effects, publication_effects: G3hPublishTool.effects,
    provider_calls: adapter.calls, released: released,
    statuses: [parent_id, child_request.execution_id].map { |id| stores.agent.executions.load(id).status },
    revisions: [parent_id, child_request.execution_id].map { |id| stores.agent.executions.load(id).execution_revision },
    history_holds: [parent.agent_id, child.agent_id].map { |id| stores.agent.retained_references(agent_id: id).size }
  }
end</code></pre>
</td></tr></tbody>
</table>

<!-- /generated-application:shared-and-normal -->

### Complete recovery helper and application function

The recovery branch uses only the original parent and public recovery APIs. It performs one reconciliation and, only when explicitly configured, one captured-write retry for confirmed pre-state. An unresolved result returns the original parent, capability and receipt to the host; it does not invoke a replacement job, loop indefinitely or release unresolved responsibility.

For example, a recovered approval-wait receipt supplies the exact request directly. A recovered approval decision uses the existing decision receipt's continuation state. Its confirmed-pre branch sends a fresh decision only when the separate `approve_after_restore` policy permits it.

<!-- generated-application:recovery -->

<!-- example: recovery-helper -->
```ruby
# This example retries only captured outcome persistence when its application
# explicitly permits that action. Wait recovery is not job completion.
def settle_parent_outcome(parent:, failure:, retry_confirmed_pre:, recoveries:)
  recovery = parent.pending_outcome_recovery(execution_id: failure.recovery.execution_id)
  raise "The exact outcome owner was not retained" unless recovery.equal?(failure.recovery)
  receipt = parent.reconcile_outcome(recovery: recovery)
  if retry_confirmed_pre && receipt.outcome == :confirmed_pre
    receipt = parent.retry_outcome(recovery: recovery)
  end
  applied = receipt.outcome == :confirmed_post && receipt.application_state == :applied && receipt.ownership_state == :released
  return {state: :recovery_pending, parent: parent, recovery: recovery, receipt: receipt} unless applied

  recoveries << {operation: :outcome, saved_outcome: receipt.saved_outcome, outcome: receipt.outcome}
  case receipt.saved_outcome
  when :coordination_wait then {state: :coordination_wait}
  when :approval_wait then {state: :approval_wait, request: receipt.approval_request}
  when :terminal
    execution = receipt.execution
    raise "Report failed: #{execution.error.inspect}" unless execution.status == :completed
    {state: :completed, result: {output: execution.result}}
  end
end

# expected_wait describes this report's two known waiting points. It is not a
# general classification of every ExecutionRehydrationRequiredError.
def await_parent_outcome(parent:, task:, expected_wait:, retry_confirmed_pre:, recoveries:)
  {state: :completed, result: task.wait_result(timeout: 5)}
rescue Phronomy::Agent::OutcomeRecoveryError => failure
  observed = settle_parent_outcome(parent: parent, failure: failure,
    retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  begin
    task.wait_result(timeout: 5)
    raise "The earlier failed observation reopened"
  rescue Phronomy::Agent::OutcomeRecoveryError => repeated
    raise "The earlier failure changed" unless repeated.equal?(failure)
  end
  observed
rescue Phronomy::ExecutionRehydrationRequiredError
  {state: expected_wait}
end

# Approval recovery only reconciles the old decision. A confirmed pre-state
# restores the exact wait; sending an approval again is a separate user policy.
def approve_report(parent:, execution_id:, request:, approve_after_restore:, retry_confirmed_pre:, recoveries:)
  task = parent.approve_async(execution_id, approval_request_id: request.id, approved: true)
  begin
    await_parent_outcome(parent: parent, task: task, expected_wait: :approval_wait,
      retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  rescue Phronomy::Agent::ApprovalRecoveryError => failure
    recovery = parent.pending_approval_recovery(execution_id: execution_id)
    raise "The exact approval owner was not retained" unless recovery.equal?(failure.recovery)
    receipt = parent.reconcile_approval(recovery: recovery)
    unless receipt.resolved?
      return {state: :recovery_pending, parent: parent, recovery: recovery, receipt: receipt}
    end
    begin
      task.wait_result(timeout: 5)
      raise "The earlier failed decision reopened"
    rescue Phronomy::Agent::ApprovalRecoveryError => repeated
      raise "The earlier decision failure changed" unless repeated.equal?(failure)
    end
    recoveries << {operation: :approval, outcome: receipt.outcome, continuation_state: receipt.continuation_state}
    if receipt.continuation_state == :restored
      unless approve_after_restore
        return {state: :approval_wait, parent: parent, request: request, receipt: receipt}
      end
      next_task = parent.approve_async(execution_id, approval_request_id: request.id, approved: true)
    else
      next_task = receipt.execution_task
    end
    await_parent_outcome(parent: parent, task: next_task, expected_wait: :approval_wait,
      retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  end
end
```

<!-- example: recovery-function -->
```ruby
# The same business process has two independent application approvals. Neither
# persistence recovery nor a recovered wait silently supplies either decision.
def run_report_with_recovery(fault:, retry_confirmed_pre: false, approve_after_restore: false)
  adapter, stores, approvals, parent = build_report_service
  parent_id = "native-report-execution"
  fault.call(stores.agent, parent_id)
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  recoveries = []
  original = parent.start_hosted(reservation: reservation, input: "Prepare and publish the report")
  first = await_parent_outcome(parent: parent, task: original, expected_wait: :coordination_wait,
    retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  return first.merge(stores: stores, execution_id: parent_id, provider_calls: adapter.calls) if first.fetch(:state) == :recovery_pending
  raise "Expected the child coordination wait" unless first.fetch(:state) == :coordination_wait
  child_request = Timeout.timeout(5) { approvals.pop }
  child = Phronomy::Agent::Base.live_for_execution(child_request.execution_id)
  child_result = child.approve_async(child_request.execution_id,
    approval_request_id: child_request.id, approved: true).wait_result(timeout: 5)
  continued = parent.resume_async(parent_id)
  second = await_parent_outcome(parent: parent, task: continued, expected_wait: :approval_wait,
    retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  return second.merge(stores: stores, child: child, execution_id: parent_id, provider_calls: adapter.calls) if second.fetch(:state) == :recovery_pending
  raise "Expected the parent's own approval" unless second.fetch(:state) == :approval_wait
  parent_request = second[:request] || Timeout.timeout(5) { approvals.pop }
  raise "Approval identifies another execution" unless parent_request.execution_id == parent_id
  final = approve_report(parent: parent, execution_id: parent_id, request: parent_request,
    approve_after_restore: approve_after_restore, retry_confirmed_pre: retry_confirmed_pre, recoveries: recoveries)
  unless final.fetch(:state) == :completed
    return final.merge(stores: stores, child: child, execution_id: parent_id, provider_calls: adapter.calls)
  end
  released = parent.unload_with_completed_child!(parent_id, execution_id: child_request.execution_id)
  {
    state: :observed, child_output: child_result.fetch(:output), parent_output: final.fetch(:result).fetch(:output),
    review_effects: G3hReviewTool.effects, publication_effects: G3hPublishTool.effects,
    provider_calls: adapter.calls, released: released,
    statuses: [parent_id, child_request.execution_id].map { |id| stores.agent.executions.load(id).status },
    history_holds: [parent.agent_id, child.agent_id].map { |id| stores.agent.retained_references(agent_id: id).size },
    recoveries: recoveries
  }
end
```

<!-- /generated-application:recovery -->

### Fault fixture and executable driver

The fault fixture is test infrastructure, separate from the application's public API. It rolls back or commits one selected parent transaction and loses its response, with immediate readback suppression where needed to expose retained recovery. It does not modify Provider or Tool behavior. The shared driver defaults to the complete normal function and selects recovery through explicit scenario, boundary/mode and independent captured-retry and fresh-approval policies.

For example, a terminal post-state fault should produce the same two effects as the normal report and a terminal outcome receipt. An approval-decision pre-state fault requires restoring the old wait and an explicitly permitted new decision before publication can run.

<!-- generated-application:fixture-and-driver -->

<!-- example: fault-fixture -->
```ruby
# This optional persistence response-loss fixture is separate from application
# policy. It does not alter Provider responses, approvals or Tool results.
module G3hOutcomeFaultScope
  def perform
    fault = coordinator.instance_variable_get(:@g3h_parent_fault)
    previous = Thread.current[:g3h_parent_fault]
    selected = fault && execution_id == fault.fetch(:execution_id) && kind == :terminal &&
      case fault.fetch(:boundary)
      when :terminal then finishing?
      when :coordination_wait then recovery_required
      when :approval_wait then !finishing? && !recovery_required
      else false
      end
    Thread.current[:g3h_parent_fault] = selected ? fault : nil
    super
  ensure
    Thread.current[:g3h_parent_fault] = previous
  end
end

module G3hApprovalFaultScope
  def commit(operation)
    with_g3h_decision_fault(operation) { super }
  end

  def commit_retained(operation, **options)
    with_g3h_decision_fault(operation) { super }
  end

  private

  def with_g3h_decision_fault(operation)
    fault = @persistence.coordinator.instance_variable_get(:@g3h_parent_fault)
    previous = Thread.current[:g3h_parent_fault]
    selected = fault && fault.fetch(:boundary) == :approval_decision && operation.execution_id == fault.fetch(:execution_id)
    Thread.current[:g3h_parent_fault] = selected ? fault : nil
    yield
  ensure
    Thread.current[:g3h_parent_fault] = previous
  end
end

module G3hAtomicFault
  def atomic(*args, &transaction)
    fault = Thread.current[:g3h_parent_fault]
    return super unless fault
    if fault[:readback]
      fault[:readback] = false
      raise IOError, "Immediate native parent readback unavailable"
    end
    return super unless fault[:armed]
    fault[:armed] = false
    fault[:attempts] += 1
    if fault.fetch(:mode) == :pre
      super do |scope|
        transaction.call(scope)
        fault[:readback] = fault.fetch(:boundary) != :approval_decision
        raise IOError, "Native parent transaction rolled back; response lost"
      end
    else
      super
      fault[:readback] = fault.fetch(:boundary) != :approval_decision
      raise IOError, "Native parent transaction committed; response lost"
    end
  end
end

Phronomy::Agent::ExecutionChange.prepend(G3hOutcomeFaultScope)
Phronomy::Agent::ApprovalResumeCommit.prepend(G3hApprovalFaultScope)

def parent_reply_loss(boundary:, mode:)
  raise ArgumentError, "Unsupported native boundary" unless %i[terminal coordination_wait approval_wait approval_decision].include?(boundary)
  raise ArgumentError, "Unsupported save outcome" unless %i[pre post].include?(mode)
  lambda do |store, execution_id|
    store.coordinator.singleton_class.prepend(G3hAtomicFault)
    store.coordinator.instance_variable_set(:@g3h_parent_fault,
      {boundary: boundary, mode: mode, execution_id: execution_id, armed: true, readback: false, attempts: 0})
  end
end
```

<!-- example: shared-driver -->
```ruby
# A running service keeps the returned parent, capability and receipt when
# recovery is pending. This one-shot demonstration reports that state and its
# cleanup result before the process ends; it is not a crash recovery service.
def run_report_example(scenario:, boundary: :terminal, mode: :post,
  retry_confirmed_pre: false, approve_after_restore: false)
  raise ArgumentError, "Unknown report scenario" unless %i[normal recovery].include?(scenario)
  begin
    value = if scenario == :normal
      run_report
    else
      run_report_with_recovery(fault: parent_reply_loss(boundary: boundary, mode: mode),
        retry_confirmed_pre: retry_confirmed_pre, approve_after_restore: approve_after_restore)
    end
    if %i[recovery_pending approval_wait].include?(value[:state])
      receipt = value.fetch(:receipt)
      report = {state: value.fetch(:state), outcome: receipt.outcome,
                application_state: receipt.application_state,
                saved_outcome: (receipt.saved_outcome if receipt.respond_to?(:saved_outcome)),
                ownership_state: (receipt.ownership_state if receipt.respond_to?(:ownership_state)),
                continuation_state: (receipt.continuation_state if receipt.respond_to?(:continuation_state)),
                provider_calls: value.fetch(:provider_calls),
                review_effects: G3hReviewTool.effects.dup, publication_effects: G3hPublishTool.effects.dup}
    else
      report = value
    end
  ensure
    Phronomy::Runtime.instance.shutdown(timeout: 0.03, cancel_grace: 0.2)
    begin
      Phronomy.reset_runtime!
      cleanup_incomplete = false
    rescue Phronomy::RuntimeShutdownError
      cleanup_incomplete = true
    end
  end
  report.merge(cleanup_incomplete: cleanup_incomplete)
end

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(run_report_example(
    scenario: ENV.fetch("G3H_SCENARIO", "normal").to_sym,
    boundary: ENV.fetch("G3H_BOUNDARY", "terminal").to_sym,
    mode: ENV.fetch("G3H_MODE", "post").to_sym,
    retry_confirmed_pre: ENV["G3H_RETRY_CAPTURED_OUTCOME"] == "true",
    approve_after_restore: ENV["G3H_APPROVE_RESTORED_WAIT"] == "true"
  ))
end
```

<!-- /generated-application:fixture-and-driver -->

Assemble the documented blocks into one Ruby file, choosing either identical normal function, and run it with the repository's bundled dependencies. These examples explicitly permit captured outcome retry or a new decision after restoring a rolled-back approval; the default policies permit neither.

```sh
bundle exec ruby /absolute/path/native_parent_outcome_application.rb

G3H_SCENARIO=recovery G3H_BOUNDARY=approval_wait G3H_MODE=pre \
  G3H_RETRY_CAPTURED_OUTCOME=true \
  bundle exec ruby /absolute/path/native_parent_outcome_application.rb

G3H_SCENARIO=recovery G3H_BOUNDARY=approval_decision G3H_MODE=pre \
  G3H_APPROVE_RESTORED_WAIT=true \
  bundle exec ruby /absolute/path/native_parent_outcome_application.rb
```

The one-shot driver summarizes pending receipts and reports `cleanup_incomplete` when retained unresolved work prevents clean shutdown. A running service instead keeps the parent/capability returned by `run_report_with_recovery` and makes its later observation or escalation decision. This demonstration does not turn process exit into durable recovery ownership.

For example, leaving captured retry disabled after a terminal pre-state returns `recovery_pending`, with the report's existing effects preserved and custody retained. Leaving reapproval disabled after an approval-decision pre-state returns the restored approval wait without running the publication Tool.

## Bound acceptance and remaining work

Acceptance distinguishes normal behavioral equivalence, intentionally changed uncertainty handling, finite model properties and remaining operations. Complete application reports and focused Runtime cases must establish the claimed paths; a passing value-object test or model alone does not prove live owner cleanup or external exactly-once effects.

For example, checking `saved_outcome: :approval_wait` is insufficient without showing that the exact request can later be approved, the old observation remains closed and the publication Tool runs once. Likewise, final save recovery must preserve actual failed/cancelled business outcomes rather than reporting all recovered facts as success.

The complete application matrix passes 14 cases: exact G3g and candidate normal runs, eight pre/post fault runs across final/coordination-wait/approval-wait/approval-decision saves, and four explicit no-retry/no-reapproval policy runs. The seven documented source blocks match the tested complete source; assembled documentation copies reproduce all 14 functional reports under source-identity checks. These application cases are separate evidence from the broader Runtime suite and finite-model checks; their counts are not added together as one coverage total.

| Acceptance boundary | Required evidence |
| --- | --- |
| Native final, coordination-wait and own approval-wait pre/post uncertainty | Same original parent, typed saved-kind receipt, complete proof and exact captured retry where authorized |
| Native own approval decision pre/post uncertainty | Same request/decision, fresh child authority, restored wait or once-only continuation |
| Mixed protected Tool and native dispatch batch | Preserve baseline factual-resolution requirement and existing effects through pre/post decision recovery; complete through the exact public resolution subject/result, without claiming automatic final resume |
| Changed, missing or unavailable authority | Retained obligation, no guessed rollback, replacement child or unauthorized continuation |
| Source and recovery observers | Earlier failed/cancelled observations stay closed; fresh receipts; no old callback replay |
| Physical work and delivery races | No stale/duplicate application, premature recovery release or unproven resubmission |
| Cancellation and lifetime | Existing authoritative cancellation and saved business meaning preserved; waits retain their applicable execution custody |
| Complete ordinary application | Same outputs, exact two Tool effects, five Provider calls, durable histories and final pair release |
| Model, API and architecture | Separate entity/observer state views; safety/conditional progress; public snapshot/RBS; unchanged responsibility direction |

The [finite native outcome model](../../spec/models/native_parent_outcome_recovery/README.md) separates saved facts, original-owner application, wait/final lifetime and client observation. Its positive model, deliberate mutations and missing-premise counterexamples have distinct expected results. It is not a refinement proof of Ruby or a guarantee that a remote Store has settled prior transactions.

The [parent outcome owner](../../spec/models/native_parent_outcome_recovery/parent-owner.svg), [approval decision owner](../../spec/models/native_parent_outcome_recovery/approval-owner.svg), [child owner](../../spec/models/native_parent_outcome_recovery/child-owner.svg) and [client observer](../../spec/models/native_parent_outcome_recovery/client-observer.svg) have separate state views. Conditional progress reaches the saved final/wait publication or approval restoration/continuation boundary; it does not assert eventual human approval, child completion or whole-job success. Fresh decision admission additionally requires stable authority between its guarded read and admission, whereas historical outcome publication allows legal later child progress.

For example, a counterexample after removing original-observer closure or after allowing release to mean job completion at an approval wait demonstrates a required invariant. A positive check still relies on explicit scheduling, authoritative settled readback and original-owner availability premises.

G3h advances completion group 1 for supported native outcomes and own approval decisions. It does not close Handoff outcome/approval/transfer lineage and current routing, arbitrary custom-participant capability/unsupported disposition, initial reserved-admission uncertainty, admitted outcome workers without complete proposals, or remaining cross-path acceptance. Mixed own protected Tool/native-dispatch batches retain their existing factual-resolution requirement; automatic completion of every native batch is not claimed. Group 2 remains failed-Runtime administration; group 3 MCP resource management; group 4 fallback child ownership; group 5 capability and existing-guarantee alignment; group 6 selected durable-backend/transport and combined final acceptance. No seventh group or process-loss takeover is introduced.

For example, a Handoff Agent can also request approval of an ordinary Tool, but its routing and custody facts cannot be proved by a native child-slot adapter. A stopped original Runtime and an unresolved remote transaction likewise require their existing separate guarantees. Ordered local guards and physical worker completion alone do not provide those guarantees.
