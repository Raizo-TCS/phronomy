# Acknowledge terminal child custody without inventing result import

A coordinating parent must account for each child it owns before releasing its local objects. Ordinary result import and final custody acknowledgement are separate ways of accounting for a terminal child. The parent may finish because a child failed before reaching the ordinary import barrier; a final guarded read can acknowledge that child's saved result without pretending that the result was used to continue the parent's business operation.

For example, a report parent delegates one approved review. The review Tool fails, and the parent's existing required-subtask policy fails the report. Both executions are terminal, but the baseline leaves the child slot unimported and rejects local pair unload. G3f records a separate parent-owned acknowledgement during parent finalization so the existing unload operation can release the quiescent pair while retaining both histories.

Baseline: applied G3e `2d896e73c607d62440993474c0ad0903523e7a54`, tree `ae87ecce69588e9949713d95601ba72ec601abd4`, PR [#467](https://github.com/Raizo-TCS/phronomy/pull/467). The original 87-file G3e delivery needed one test-support require relocation; its 86 other files and all production code are unchanged. The applied head passed four workflows and 14 jobs. This document describes the G3f candidate; its exact commit and verification results belong to the accompanying delivery evidence. Contract concept v55 and foundation v48 remain the architecture references.

## Separate parent disposition from child execution

The child owns its execution and any retained recovery operation. The parent owns its coordination slot and decides how a child's result affects the parent. Local unload additionally requires both owners to be physically quiescent; durable history retention is a separate responsibility.

For example, the child may already have a saved failed result while its original terminal-save worker is still retained. The parent can acknowledge that result and fail the report, but unloading the pair remains refused until the child's original recovery owner releases its local admission.

| Fact | Owner and evidence | Consequence |
| --- | --- | --- |
| Child result is terminal | Exact child observation and opaque reservation | The result can be read; local child work may still be retained |
| Ordinary import progressed | Existing parent dispatch barrier and `imported` flag | Existing parent continuation semantics apply |
| Final custody was acknowledged | Parent terminal transaction and separate `terminal_acknowledgement` receipt | Parent has adopted the exact saved terminal outcome for custody disposition; no callback-delivery or successful-business-import claim |
| Local pair can be unloaded | Existing exact single-child relationship, matching holds, terminal parent and child, valid disposition, and no admitted local work | Existing `unload_with_completed_child!` can release the local pair |
| History can be discarded | Separate existing history policy and authority | Neither acknowledgement nor local unload grants this permission |

The acknowledgement does not change the `imported` flag. A failed required review remains a failed child and failed parent with `imported: false`. An unrelated parent failure may also acknowledge an already-terminal child under the same guarded read: this means the parent has accounted for that child's custody, not that the child's callback determined the parent outcome.

## Record acknowledgement in the parent's final transaction

The coordinating domain reads each eligible terminal child under the parent's ordered transaction guards and records its exact outcome identity with the parent's final state. An acknowledgement must describe the same parent execution, slot and child reservation, and it must not appear without the corresponding parent finalization.

For example, a child reserved by report execution A cannot satisfy report execution B's acknowledgement even if its Tool name and output match. An active, suspended, absent or differently reserved child remains unacknowledged. A parent coordination wait also does not create a terminal acknowledgement.

The native coordinator acts only when `ExecutionChange#finishing?` is true and its existing pending-coordination rule does not keep the parent active. It skips ordinarily imported children. The immutable extension records this receipt for every remaining eligible child:

| Receipt field | Meaning |
| --- | --- |
| `version` | Receipt schema version, currently `1` |
| `agent_id`, `execution_id` | Exact observed child identity |
| `reservation` | Native parent kind, parent Agent ID, parent execution ID and slot |
| `status` | Exact saved child terminal status |
| `outcome_digest` | SHA-256 of recursively key-sorted JSON containing materialized `result`, `raw_output`, `error` and `transfer_receipt` |

The digest preserves array order and JSON primitive types while sorting object keys recursively. It uses ordinary JSON encoding rather than the stricter `CanonicalJSON` input contract, so valid structured outputs containing large integers or negative zero are not rejected by this custody operation. The digest avoids copying potentially large result bodies into the parent extension. The retained child history remains the result source. The acknowledgement is not an authorization token and its digest is not a digital signature. Its authority comes from the existing guarded parent transaction and exact stored relationship.

The digest excludes the cancellation-intent ledger, retention records and unrelated revisions: those can legitimately change without rewriting the historical terminal result. Pair release rereads the child and reconstructs the receipt, so changed identity, reservation, status or terminal content cannot reuse the old acknowledgement. Missing or unreadable result evidence does not establish matching custody.

Parent root, execution, journal, opaque extension content and retention evidence remain covered by the existing complete `ExecutionChange` save comparison. A lost response with a matching complete post-state can use that immediate readback. A rolled-back or still-unknown participant save does not gain a new retained parent recovery operation in G3f. If the original observation failed during an unknown readback but a later unload can freshly verify the committed parent, matching acknowledgement and quiescent owners, that unload can succeed while the original observation stays failed. An unreadable current unload proof cannot establish release. No Provider, Tool, preparation hook or participant transaction is replayed merely to infer the outcome.

## Keep application behavior explicit

The application continues to choose child policy, approval and later management actions through existing APIs. The library removes the need to invent a successful result import merely to close the local pair after a failed child. It does not remove error reporting or authorize history deletion.

For example, the complete report application below gets the child execution ID from its public approval request, approves the review, observes both saved outcomes and attempts the existing pair unload. The same complete source runs on both versions. Successful-review behavior is equivalent; failed-review local release is the intentional behavior change.

| Observable behavior | Applied G3e | G3f candidate |
| --- | --- | --- |
| Successful review | Child `review ready`, parent `report ready`, four Provider calls, one Tool effect, pair unload succeeds | Same |
| Required review fails | Child and parent fail with their existing diagnostics; two Provider calls and one Tool effect | Same business outcome and work counts |
| Local unload after that failure, with both owners quiescent | Refused because ordinary import did not occur | Allowed by matching final acknowledgement |
| Ordinary `imported` progress on that failure | `false` | Remains `false`; separate acknowledgement is present |
| Parent and child history holds after local unload | Remain present | Remain present |
| Failed original caller observation | Stays failed | Stays failed |
| Child cancellation under `:raise` or `:skip` | Parent follows its existing failure policy; cancellation is not skipped | Same policy; final acknowledgement can enable local unload |
| Child failure under `:skip` | Existing ordinary import and continuation | Same |

### Shared application setup

The setup supplies the same parent, child, protected Tool, deterministic offline Provider and in-memory composition to both versions. The Provider supplies normal Tool requests and final answers; it does not simulate the acknowledgement implementation.

For example, the Provider first requests the reviewer and then the protected report read. With failure enabled, the Tool raises after recording its one effect; there are no subsequent successful-review or report-generation calls.

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"
require "timeout"

class G3fReviewTool < Phronomy::Tool::Base
  tool_name "review_one_report"
  description "Read the approved report once"
  requires_approval true
  on_error :raise

  class << self
    attr_accessor :effects, :fail_review
  end

  def execute(query:)
    self.class.effects << query
    raise IOError, "report review failed" if self.class.fail_review
    "reviewed #{query}"
  end
end

class G3fReviewAgent < Phronomy::Agent::Base
  agent_definition id: "child-execution-reviewer", version: 1
  model "offline-model"
  tools G3fReviewTool => nil
end

class G3fReportParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "child-execution-parent", version: 1
  model "offline-model"
  subagent :reviewer, G3fReviewAgent
end

class G3fReportAdapter < Phronomy::LLMAdapter::Base
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

def build_report_service(fail_review: false)
  G3fReviewTool.effects = []
  G3fReviewTool.fail_review = fail_review
  adapter = G3fReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  stores = Phronomy::PersistenceComposition.in_memory
  approvals = Queue.new
  parent = G3fReportParent.create(agent_id: "child-execution-parent", persistence: stores.agent,
    coordination_store: stores.multi_agent,
    on_event: ->(event) { approvals << event.payload.fetch(:request) if event.type == :approval_required })
  [adapter, stores, approvals, parent]
end
```

### Complete before and after function

The function retains the existing approval, observation and cleanup responsibilities on both sides. Each column is a complete source unit using the shared setup; no branch is omitted to make the changed library appear simpler.

For example, the failed original approval observation remains recorded in `child_error`, while later exact observations supply the durable child and parent diagnostics. A cleanup refusal is reported as `released: false`; the application does not reinterpret it as success.

<table class="source-comparison">
<thead><tr><th>Applied G3e baseline</th><th>G3f candidate</th></tr></thead>
<tbody><tr><td valign="top">
<!-- example: application-before --><pre><code># The approval request supplies the exact public child identity.
# The same complete application runs unchanged before and after the library fix.
def run_report(fail_review: false)
  adapter, stores, approvals, parent = build_report_service(fail_review: fail_review)
  parent_id = &quot;child-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: &quot;Prepare the report&quot;)
  request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent retains its saved coordination wait for this child approval.
  end
  child = Phronomy::Agent::Base.live_for_execution(request.execution_id)
  child_error = parent_error = nil
  begin
    child.approve_async(request.execution_id,
      approval_request_id: request.id, approved: true).wait_result(timeout: 5)
  rescue Phronomy::Error =&gt; error
    child_error = {class: error.class.name, message: error.message}
  end
  begin
    parent.resume(parent_id)
  rescue Phronomy::Error =&gt; error
    parent_error = {class: error.class.name, message: error.message}
  end
  parent_result = parent.resume(parent_id)
  child_result = child.resume(request.execution_id)
  released = begin
    parent.unload_with_completed_child!(parent_id, execution_id: request.execution_id)
  rescue Phronomy::AgentBusyError
    false
  end
  {
    child_status: child_result.fetch(:status), parent_status: parent_result.fetch(:status),
    child_output: child_result[:output], parent_output: parent_result[:output],
    child_error: child_error, parent_error: parent_error,
    child_diagnostic: child_result[:error], parent_diagnostic: parent_result[:error],
    tool_effects: G3fReviewTool.effects, provider_calls: adapter.calls, released: released,
    history_holds: [parent.agent_id, child.agent_id].map do |id|
      stores.agent.retained_references(agent_id: id).length
    end
  }
end</code></pre>
</td><td valign="top">
<!-- example: application-after --><pre><code># The approval request supplies the exact public child identity.
# The same complete application runs unchanged before and after the library fix.
def run_report(fail_review: false)
  adapter, stores, approvals, parent = build_report_service(fail_review: fail_review)
  parent_id = &quot;child-report-execution&quot;
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: parent.agent_id, execution_id: parent_id)
  original = parent.start_hosted(reservation: reservation, input: &quot;Prepare the report&quot;)
  request = Timeout.timeout(5) { approvals.pop }
  begin
    original.wait_result(timeout: 5)
  rescue Phronomy::ExecutionRehydrationRequiredError
    # The parent retains its saved coordination wait for this child approval.
  end
  child = Phronomy::Agent::Base.live_for_execution(request.execution_id)
  child_error = parent_error = nil
  begin
    child.approve_async(request.execution_id,
      approval_request_id: request.id, approved: true).wait_result(timeout: 5)
  rescue Phronomy::Error =&gt; error
    child_error = {class: error.class.name, message: error.message}
  end
  begin
    parent.resume(parent_id)
  rescue Phronomy::Error =&gt; error
    parent_error = {class: error.class.name, message: error.message}
  end
  parent_result = parent.resume(parent_id)
  child_result = child.resume(request.execution_id)
  released = begin
    parent.unload_with_completed_child!(parent_id, execution_id: request.execution_id)
  rescue Phronomy::AgentBusyError
    false
  end
  {
    child_status: child_result.fetch(:status), parent_status: parent_result.fetch(:status),
    child_output: child_result[:output], parent_output: parent_result[:output],
    child_error: child_error, parent_error: parent_error,
    child_diagnostic: child_result[:error], parent_diagnostic: parent_result[:error],
    tool_effects: G3fReviewTool.effects, provider_calls: adapter.calls, released: released,
    history_holds: [parent.agent_id, child.agent_id].map do |id|
      stores.agent.retained_references(agent_id: id).length
    end
  }
end</code></pre>
</td></tr></tbody></table>

### Complete application driver

The driver selects the ordinary or deliberately failed review and reports the same result structure. The example uses an isolated Runtime and in-memory history; a service must keep unresolved owners and its durable backend available according to its management policy.

For example, the ordinary invocation prints successful outputs, while `--fail-review` prints the preserved failure diagnostics and whether the local pair was released. This example has no outstanding child save-recovery operation at driver shutdown.

<!-- example: shared-driver -->
```ruby
if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.pretty_generate(run_report(fail_review: ARGV.include?("--fail-review")))
  ensure
    Phronomy.reset_runtime!
  end
end
```

## Preserve symmetry without adding a management facade

Comparable operations share the existing distinction between recorded facts, business policy and physical ownership. The native parent gains one domain-specific persisted fact, while child recovery, Team coordination and history disposal retain their own responsibilities.

For example, a child terminal recovery receipt can prove that the child's saved failure is applied and its owner released. It cannot set the native parent's acknowledgement or release Team slots; those decisions belong to their respective parent domains.

| Concern | Existing ordinary import | Final native acknowledgement | Decision |
| --- | --- | --- | --- |
| Result meaning | Parent reaches ordinary continuation/import barrier | Parent accounts for exact terminal child while ending | Keep separate facts; neither implies the other |
| Public method and result shape | Existing Agent and Orchestrator API | Same public API and return shapes | Adopt existing operations; no new sync/async or stream variant |
| Parent error policy | `:raise` / `:skip`, with cancellation not skipped | Does not re-evaluate or rewrite that policy | Preserve |
| Saved evidence | Opaque native extension | Same extension with a versioned receipt | Keep with the coordinating domain |
| Child local recovery | Original child owns it | Original child still owns it | Preserve independent ownership |
| Local release | Exact completed-pair checks plus quiescence | Same checks, allowing valid acknowledgement as a second disposition | Extend evidence, retain safeguards |
| History release | Separate domain decision | Separate domain decision | Defer broader history-disposal changes |
| Team / Handoff / custom participant | Their own state and authority | No new inferred support | Defer to explicit acceptance for those domains |

Simply marking every observed terminal child as `imported` was rejected because it would invent business-import progress. A generic Tool completion flag was also rejected as sufficient proof of child result consumption: a wrapper can time out or cancel before the actual child callback. A final guarded adoption deliberately makes a narrower, explicit claim and needs no new Agent SPI, volatile receipt registry or public convenience layer.

## Check boundaries and acceptance limits

The coordinating domain interprets native slots and acknowledgements, while Agent supplies existing execution observations, guarded transactions and local lifetime checks. Keeping the change in that domain avoids a reverse dependency from Agent into MultiAgent and avoids a separate cross-domain job manager.

For example, the same `Agent::ExecutionObservation` used for exact child observation supplies the materialized terminal result. The parent coordinator computes its own receipt and stores it as opaque extension content; Agent does not learn native child-slot semantics.

The behavioral production change is confined to `MultiAgent::DurableSubagentCoordinator`; the existing Orchestrator unload comment is updated to describe the additional acknowledgement disposition. No public API, RBS signature, dependency, persisted Agent execution format, Team implementation or Workflow implementation is added. Existing native extension objects remain readable; old unimported histories without an acknowledgement are not silently backfilled. Resuming an already-terminal historical parent only observes its saved result and does not create a new acknowledgement. Explicit history disposition remains a separate existing application decision. The single-child pair-unload API remains restricted to one direct child, even though parent finalization may acknowledge several terminal slots.

Both current Contract SVGs remain reference points for dependency direction and responsibility review. Their unchanged selected Contract graphs are not proof that the complete Ruby graph is acyclic. Candidate source-graph comparisons, Runtime acceptance and finite-model expectations are recorded with the delivery. The [bounded parent/child model](../../spec/models/parent_child_result_import/README.md) keeps parent custody, child physical ownership and caller observation separate; it is not a Ruby refinement proof. The complete application was run in four separate real-Runtime processes against exact baseline and candidate checkouts. The normal result objects match completely. For the failed review, only `released: false` becoming `released: true` differs; saved business diagnostics, Provider/Tool counts and history holds match.

Required bounded acceptance includes the six ordinary success/failure/cancellation and `:raise`/`:skip` combinations; unchanged business diagnostics, Provider/Tool counts and holds; exact-identity and outcome tampering; active, absent and suspended exclusions; atomic save rollback and committed-response loss; child-local recovery still blocking premature unload; earlier parent histories; and a separate parent/child/caller model. Each claim is limited to the cases actually recorded in the final evidence.

G3f advances the native parent-custody item within completion group 1. Native participant save recovery after unresolved immediate readback, Handoff, custom participant capability, nonterminal wait establishment and remaining cross-path acceptance stay open. Group 2 remains management after Runtime failure; group 3 remains MCP resource management; group 4 remains fallback child ownership; group 5 remains capability and existing-guarantee alignment; group 6 remains selected durable-backend/transport and combined final acceptance. No seventh completion group is introduced.

That paragraph records the G3f boundary. Subsequent [G3g native dispatch recovery](native-parent-dispatch-recovery.md) and [G3h native final/wait and own approval recovery](native-parent-outcome-recovery.md) advance the supported native participant paths within the same group 1. They preserve this acknowledgement contract and do not close Handoff, arbitrary participant support or the other completion groups.
