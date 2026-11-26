# Original-owner Agent terminal recovery

Phronomy separates a saved Agent outcome from the original live owner's application of that outcome. The Agent owns terminal interpretation, live state, accepted-job responsibility and observation. Persistence supplies atomic guarded records; a Runtime supplies serial delivery and workers. G3b-2 connects the private G3b-1 proof to the original Agent owner without moving domain decisions into those lower layers.

For example, a research Agent calculates an answer, commits its terminal records, then loses the save response and its first confirmation read. Another `resume` may retrieve that answer while the original invocation remains pending and the Agent stays busy. The new recovery operation addresses the retained original owner instead of treating that separate read as completion.

Baseline: G3b-1 `e4a57fa278ed5136679ad884a8a4c51fa585382e`. This document describes the G3b-2 implementation candidate and its explicit acceptance boundary. The delivery evidence records the exact final commit and actual check results. Contract concept v55 and foundation v48 are the canonical architecture references.

The later [correlated-child execution recovery contract](agent-child-execution-recovery.md) extends actual terminal recovery to supported original correlated child owners. Child-local release remains separate from parent result import and retention-based peer release.

## Preserve responsibility after an observation ends

The original Agent owner retains an uncertain terminal operation before exposing its recovery capability. The original caller's observation can then end with an explicit recovery error while the accepted job remains owned. A later recovery request creates a new observation; it does not reopen an earlier failed or cancelled TaskResult.

For example, an application awaiting `invoke_async` receives `Agent::TerminalRecoveryError`. Its recovery reference remains usable even if that application discards the failed task. If the original observer cancelled before receiving the error, `pending_terminal_recovery(execution_id:)` discovers the retained operation by the accepted execution identity.

This intentionally changes the baseline fault path from an unexplained indefinite wait to an observation error with retained responsibility. It is not a business-failure verdict. Ending an observer's lease is not permission to release the accepted job: the retained terminal operation, Agent admission and physical-attempt tracking continue to enforce custody. A source task's physical completion describes its tracked work, not durable job resolution.

Normal initial completion still uses the existing success, failure, cancellation and event-listener behavior. Once the original observation has ended, later recovery does not replay its event or stream listener. Its result is delivered only through the new recovery observation.

## Separate readback from persistence retry

An explicit readback determines the saved fact and may apply a confirmed post-state to the original owner. An explicit save retry has the additional authority to repeat captured persistence writes. Neither operation recomputes a terminal decision or repeats application work.

For example, after a rollback, `reconcile_terminal` returns `confirmed_pre` and leaves the Agent's accepted job active. If the application permits saving the already computed answer, `retry_terminal` rechecks the complete pre-state inside the write transaction and restores the retained bytes, references, journal identities and records.

| Method | Behavior |
| --- | --- |
| `pending_terminal_recovery(execution_id:)` | Local lookup on the original Runtime's existing registry. No persistence I/O, new Runtime or coordinator. Returns nil when absent or owned by a different Agent incarnation. |
| `reconcile_terminal_async(recovery:)` | A fresh `TaskResult<TerminalRecoveryResult>` for classification and original-owner application. It performs no persistence write. |
| `reconcile_terminal(recovery:)` | Blocking host-thread form of the same operation. EventLoop blocking is rejected. |
| `retry_terminal_async(recovery:)` | A fresh observation of an explicitly requested captured-write retry. An exact post-state causes no duplicate write; changed evidence prevents replay. |
| `retry_terminal(recovery:)` | Blocking host-thread form of the same persistence retry. |

The lookup requires a nonempty String. Recovery calls require the exact process-local `Agent::TerminalRecovery` belonging to this Agent object and operation. Invalid references raise ArgumentError before persistence access. A capability contains diagnostic `agent_id`, `execution_id` and `recovery_id` readers and has no public constructor. Copying those strings does not reconstruct authority.

`resume` retains its separate meaning: continue or observe an execution through durable Agent recovery. `resolve` retains its meaning of supplying a factual outcome for an ambiguous provider/Tool subject. Neither is an alias for terminal save-only retry.

## Report saved facts and owner progress independently

A recovery result distinguishes persistence classification, application by the original serial owner, and release of accepted-job responsibility. The optional execution observation represents the saved job, while the top-level error describes the recovery operation.

For example, saving a failed execution successfully produces a fulfilled recovery observation with `execution.status == :failed` and a saved diagnostic in `execution.error`. It does not reject the recovery task merely because the job failed. An unavailable read is instead a recovery error and leaves the job's status unclassified.

| Result field | Meaning |
| --- | --- |
| `recovery`, `agent_id`, `execution_id`, `recovery_id` | The same retained operation and its diagnostic identities. |
| `outcome` | `confirmed_post`, `confirmed_pre`, `unresolved` or `unavailable`. |
| `application_state` | `pending` or `applied` on the original Agent owner. |
| `ownership_state` | `retained` or `released`; release requires application and physical quiescence. |
| `revision` | The positive execution revision of a confirmed post-state; otherwise nil. |
| `execution` | An immutable `Agent::ExecutionObservation` of the confirmed terminal job, if available; otherwise nil. |
| `error` | A recovery/application error, separate from `execution.error`. |

Only a confirmed post-state permits application and release. A confirmed pre-state remains `pending` / `retained`; it is not permission to abandon the active Agent job. Conflicting evidence is `unresolved`. An unavailable worker, read or original owner is `unavailable`. A previously confirmed post-state remains a confirmed fact even if subsequent application or delivery becomes unavailable: it can report `confirmed_post` / `pending` / `retained` with an error.

The error's code is `agent.terminal_recovery`. `TerminalRecoveryError.original_error` preserves the original persistence/operation failure; `cause` preserves the immediate operation failure. The private owner separately retains the actual computed terminal exception, including an OutputError created during validation. Reconstructing arbitrary original exceptions from persistence diagnostics or rerunning validation is unnecessary and unsafe.

## Keep normal application code equivalent

Normal public invocation and exact-result observation use the same application code before and after this change. The equivalence claim is limited to the measured normal path: output, saved execution, transcript, revisions, provider count and completion. The fault path intentionally changes and is described separately below.

For example, the deterministic local adapter returns the structured answer `ordinary answer`. Both versions invoke it once, observe the result through `resume`, and produce the same functional report. The application function uses only public Agent APIs; the separate measurement function reads private records strictly as test evidence.

<table>
<thead><tr><th>G3b-1 baseline</th><th>G3b-2 candidate</th></tr></thead>
<tbody><tr><td><pre lang="ruby">def run_normal_application(persistence:)
  agent = G3NormalApplicationAgent.create(agent_id: &quot;g3-normal-agent&quot;, persistence: persistence)
  source_task = agent.invoke_async(&quot;ordinary question&quot;, output_schema: {
    type: &quot;object&quot;, properties: {answer: {type: &quot;string&quot;}},
    required: [&quot;answer&quot;], additionalProperties: false
  })
  source_result = source_task.wait_result(timeout: 5)
  observed_result = agent.resume(source_result.fetch(:execution_id))
  [agent, source_task, source_result, observed_result]
end</pre></td><td><pre lang="ruby">def run_normal_application(persistence:)
  agent = G3NormalApplicationAgent.create(agent_id: &quot;g3-normal-agent&quot;, persistence: persistence)
  source_task = agent.invoke_async(&quot;ordinary question&quot;, output_schema: {
    type: &quot;object&quot;, properties: {answer: {type: &quot;string&quot;}},
    required: [&quot;answer&quot;], additionalProperties: false
  })
  source_result = source_task.wait_result(timeout: 5)
  observed_result = agent.resume(source_result.fetch(:execution_id))
  [agent, source_task, source_result, observed_result]
end</pre></td></tr></tbody>
</table>

The following shared setup precedes either complete function. It defines the Agent and the deterministic adapter; no private recovery or capture hook is installed by the example.

For example, replacing only the framework checkout while retaining this setup and the function above provides a controlled normal-behavior comparison without a network LLM.

```ruby
# frozen_string_literal: true

# Run from the repository root with its bundled dependencies. This deterministic
# fixture adapter performs no network request. The application operation uses
# public Agent APIs without installing any private capture or recovery hook.
# The separate measurement helper reads private persistence records solely as
# test evidence; production capture behavior is whatever the tested version provides.
require "phronomy"
require "json"

class G3NormalFixtureAdapter < Phronomy::LLMAdapter::Base
  attr_reader :request_count

  def initialize
    @request_count = 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @request_count += 1
    Phronomy::LLMAdapter::Response.new(
      content: '{"answer":"ordinary answer"}', finish_reason: :stop,
      usage: Phronomy::LLMAdapter::TokenUsage.new(input: 4, output: 2)
    )
  end
end

class G3NormalApplicationAgent < Phronomy::Agent::Base
  agent_definition id: "g3-normal-behavior", version: 1
end
```

The shared measurement and driver below follow either complete function. They record equivalent observable values and shut down the normal-path Runtime after measurement. They are test scaffolding, not hidden application recovery policy.

For example, the JSON report omits random execution identifiers and wall-clock timestamps while retaining execution revision, journal shape, output, physical completion and exact provider count.

```ruby
def functional_observation(agent:, source_task:, source_result:, observed_result:, adapter:)
  store = agent.persistence
  execution = store.executions.load(source_result.fetch(:execution_id))
  journal = store.journals.read(agent.agent_id, after: 0)
  {
    result: source_result.slice(:output, :raw_output, :agent_revision, :context_revision, :journal_position)
      .merge(usage: source_result.fetch(:usage).to_h),
    transcript: source_result.fetch(:messages).map(&:to_h),
    durable_status: execution.status,
    durable_phase: execution.phase,
    durable_revision: execution.execution_revision,
    durable_result: store.contents.fetch_text(execution.result_ref),
    durable_raw_output: store.contents.fetch_text(execution.metadata.fetch("raw_output_ref")),
    journal: journal.map { |record| record.to_h.slice("kind", "channel", "role", "sequence", "context_candidate") },
    stored_llm_calls: execution.llm_calls.size,
    live_root_status: agent.agent_root.lifecycle_status,
    source_done: source_task.done?,
    source_physical_complete: source_task.physical_complete?,
    provider_calls: adapter.request_count,
    resumed_output: observed_result.fetch(:output)
  }
end

if $PROGRAM_NAME == __FILE__
  begin
    adapter = G3NormalFixtureAdapter.new
    Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
    agent, source_task, source_result, observed_result =
      run_normal_application(persistence: Phronomy::PersistenceComposition.in_memory.agent)
    raise "Unexpected output" unless source_result.fetch(:output) == {"answer" => "ordinary answer"}
    raise "Resume changed the output" unless observed_result.fetch(:output) == source_result.fetch(:output)
    raise "Provider was replayed" unless adapter.request_count == 1
    observation = functional_observation(agent: agent, source_task: source_task,
      source_result: source_result, observed_result: observed_result, adapter: adapter)
    File.write(ENV.fetch("G3_NORMAL_REPORT"), JSON.pretty_generate(observation) + "\n")
  ensure
    Phronomy.reset_runtime!
  end
end

```

Run the assembled source with the repository's bundled dependencies and set `G3_NORMAL_REPORT` to an output filename. The full source is included in the delivery evidence. The exact normal function was executed against the G3b-1 baseline and this candidate with equal functional JSON reports. The documented application check also executes that same function directly and compares it with the baseline report; syntax alone is not used as evidence of equivalence.

## Make the application's retry policy explicit

Applications choose whether to retry a captured save and what to do when recovery remains unresolved. Phronomy retains the exact original responsibility and prevents business work from being repeated; it does not choose an application's retry schedule, escalation or publication policy.

For example, the complete function below performs one readback and at most one explicitly permitted save retry. It returns the recovery reference and receipt when still pending. Its caller continues to own the Agent and Runtime and can schedule another explicit observation without invoking the provider again.

```ruby
# frozen_string_literal: true

require "phronomy"

# The caller owns this Agent and its Runtime, and explicitly chooses whether a
# confirmed pre-state may be saved again. No provider or Tool is started here
# after the initial invocation. Pending recovery is returned to that owner.
def run_recoverable_request(agent:, input:, retry_save: false)
  result = agent.invoke(input)
  {state: :completed, result: result}.freeze
rescue Phronomy::Agent::TerminalRecoveryError => failure
  recovery = failure.recovery
  receipt = agent.reconcile_terminal(recovery: recovery)
  if retry_save && receipt.outcome == :confirmed_pre
    receipt = agent.retry_terminal(recovery: recovery)
  end
  if receipt.outcome == :confirmed_post && receipt.application_state == :applied &&
      receipt.ownership_state == :released && receipt.execution
    {state: :observed, execution: receipt.execution.to_result,
     recovery: recovery, receipt: receipt}.freeze
  else
    {state: :recovery_pending, recovery: recovery, receipt: receipt}.freeze
  end
end
```

The function requires an already created live Agent and a host thread. `retry_save` defaults to false. Its normal return preserves the invocation result; its recovered return exposes a saved execution outcome, which may be completed, failed or cancelled. The application must inspect that status before treating it as a business success. The `recovery_pending` branch does not unload the Agent, create another Runtime or claim cleanup succeeded.

The exact function above was executed in five real-Runtime scenarios: ordinary success, committed reply loss, rollback with retry disabled, rollback with retry enabled, and a failed job whose terminal save was retried. Together with the exact normal comparison, all six documented-application checks passed. Only the storage failure is injected; the Agent, Runtime, admission, terminal construction, readback and owner application are real. These six checks do not establish the other race, shutdown or external-backend properties listed below.

The application no longer needs to guess whether a returned durable result released the old owner, retain private transaction snapshots, reconstruct journal writes, or replay provider work to make progress. It still decides whether a save retry is permitted, how long to observe, how to report a failed saved job, and how to retain or escalate unresolved responsibility.

## Bound observation and physical-attempt lifetimes

Each request returns a fresh observation while the original owner serializes physical persistence attempts. Cancelling or timing out one observation does not revoke an accepted physical attempt or the accepted Agent job. A subsequent observation can inspect the retained fact or result.

For example, two concurrent reconciliation requests join one physical read. Cancelling the first observer leaves the second observer and the owner intact. A retry requested while a read is physically active is refused as unavailable rather than silently promoting that read into a write.

Same-kind requests can share one physical attempt. A different-kind request does not start a concurrent attempt. After an unavailable or unresolved attempt, a later explicit request may try again. Confirmed-pre is not cached as a final receipt: the still-active job's cancellation ledger or records may change, so a new observation rereads them. Every write retry rechecks the full pre-state in its transaction.

A confirmed, applied and released post-state remains available through a previously held capability without persistence I/O, callback replay or a new owner. Resolved operations leave the pending index. Old references cannot affect later Agent incarnations or sessions. Recovery validates original Agent identity, execution, session, expected revision and retained operation, and release waits for the original save and any recovery attempt to be physically complete.

## Preserve custody through Runtime drain and stop

Runtime cleanup and accepted-job resolution are distinct. The original running or draining owner may finish an accepted recovery. If uncertainty remains when the Runtime stops, the retained capability reports unavailability and cleanup remains incomplete; no operation is redirected to another Runtime.

For example, shutdown during a blocked retry cannot claim complete cleanup solely because the original observation has already failed. If that attempt finishes and its confirmed outcome is applied before shutdown ends, cleanup can complete. If it cannot finish, the unresolved owner remains retained.

A stopped owner is not recoverable through this process-local API. Transfer to another Runtime, a durable recovery-ticket format, process-crash recovery and cross-process coordination are outside this stage. Retaining an in-memory capability is not durable storage. An application must not discard its owning process and infer that the job was resolved.

## State the proof and backend boundaries

The integration can reconcile or retry only a complete captured terminal proposal whose original owner is still running or draining. Physical worker completion is required for local serialization but does not prove that an arbitrary remote backend transaction has settled or that a later read is authoritative.

For example, if terminal submission is rejected before the worker starts, the accepted Agent job still needs custody but no complete encoded proposal exists. The original observer receives a recovery error and the owner stays retained; readback/retry reports unavailable rather than inventing records or rerunning the encoder.

The same limitation applies to a failure before full proposal capture. This stage does not add first-time terminal encoding or business replay through the save-only retry API, and it does not complete every Agent terminal failure case. A known complete late worker outcome can still supply conclusive evidence under the original operation's protocol.

The later [terminal submission recovery contract](agent-terminal-submission-recovery.md) adds a separate explicit operation for mechanism-proven non-admission. It does not broaden `retry_terminal`: accepted work that fails before complete capture still cannot be resubmitted through that operation.

The caller/backend must establish that the prior backend transaction has settled and that authoritative readback is ordered after it. The Store must provide its guard exclusion and atomic transaction semantics. Local worker return, revisions or CAS alone do not establish those remote conditions. External database/LLM acceptance is separate from in-memory fault injection.

The original G3b stage covered an installed standalone Agent's completed, failed or cancelled terminal save. G3e additionally supports the correlated-child actual terminal paths described in [child execution recovery](agent-child-execution-recovery.md). Parent participant coordination, execution extensions, approval suspension, handoff, initial preparation and dispatch recovery retain separate contracts; the child eligibility extension does not include those boundaries.

## Retain justified symmetry without a generic manager

Agent and Workflow share the rule that persistence evidence, observation and ownership release are different facts. Their saved representations and pre-state obligations differ, so this stage shares existing neutral facilities while keeping terminal decisions in each domain.

For example, a Workflow segment's confirmed pre-state can release its failed terminal attempt under G2 policy. An Agent's confirmed pre-state still contains an active accepted job and needs retained custody plus a guarded save retry. Forcing both through one release callback would erase that difference.

| Dimension | Workflow G2 | Agent G3b-2 | Decision |
| --- | --- | --- | --- |
| Recovery reference | Original compiled Workflow, process-local | Original Agent incarnation, process-local | Adopt the same capability rule. |
| Observation names | `reconcile_terminal[_async]` | Same verbs and keyword | Adopt symmetry. |
| Pending discovery | `workflow_instance_id:` | `execution_id:` within this Agent | Use each domain's accepted-job identity. |
| Read/write distinction | Reconciliation never saves | Reconciliation never saves; explicit `retry_terminal[_async]` can save captured bytes | Retain justified extra operation. |
| Confirmed pre-state | G2 policy may apply and release | Pending and retained | Preserve domain semantics. |
| Saved result | Workflow context and revision | ExecutionObservation and execution revision | Reuse existing domain views. |
| Error and observation | Recovery error does not prove business failure; original observation stays closed | Same rule, including failed/cancelled saved executions | Adopt symmetry. |
| Lifetime | Physical-attempt serialization and stopped-owner unavailability | Same rule with Agent admission and original terminal ownership; G3b standalone and the later G3e supported child scope | Reuse neutral facilities; keep domain application local. |

No new generic recovery manager is justified by this stage. The review must assess removed duplicate code, adapter burden, comprehension, duplicate state authority, shared defect corrections, total tests and execution/retention cost together. Similar public verbs alone do not prove that a shared implementation simplifies Agent, Team and Workflow.

## Verify the original-owner behavior

Acceptance must exercise actual Agent, Runtime, persistence and observation interactions, including races and injected delivery failures. Finite models check stated transition rules and premises; they do not prove that Ruby implements the model or that every backend satisfies it.

For example, commit/reply-loss/read-loss must later produce the saved answer, update the original live Agent, release its exact admission only after physical completion, avoid old listener replay, and allow a new invocation. A passing constructor test alone establishes none of those properties.

The delivery's validation summary records measured test counts and limits. Required cases include confirmed post, retained confirmed pre, exact content retry, failed/cancelled/OutputError outcomes, cancelled original and recovery observers, same-kind concurrency, mixed-kind refusal, rejected/lost delivery, stale identity/session, changed cancellation evidence, repeated resolved receipts, draining success and stopped incomplete cleanup. Normal compatibility uses the complete comparison above; fault behavior is intentionally different:

| Trigger | G3b-1 baseline | G3b-2 candidate |
| --- | --- | --- |
| Complete terminal proposal, initial readback unavailable | Original call can remain pending without public recovery | Original observation ends with a recovery capability; original job remains owned. |
| Later confirmed post | Separate resume can return data while old owner stays busy | Explicit recovery applies and releases the exact original owner, then returns a new receipt. |
| Later confirmed pre | No connected public save-only remedy | Explicit retry may persist the same proposal after full guarded recheck. |
| Complete proposal unavailable | No complete saved retry material | Custody remains retained and recovery is unavailable; no fabricated write. |
| Unresolved shutdown | Cleanup could discard local Agent custody | Cleanup remains incomplete and the stopped original owner is not replaced. |

Both canonical Contract diagrams require review for direction, responsibility, cycles and unjustified layer skipping. The source dependency graph has existing cycles; acyclicity of selected Contract diagrams is not a claim that all source files form a DAG. Public API snapshots, RBS, annotations, full changed-file English checks, archive integrity and actual bundle application are additional delivery checks, not substitutes for the lifecycle acceptance cases.

## Preserve custody when submission is uncertain

Terminal recovery retains the original owner whenever a submitted worker may still execute. Positive executor rejection, returned handles and physical completion remain separate from whether the caller received a response.

For example, an adapter that queues a reconciliation read and then loses its handle must not permit a second read or release the owner. See [recovery submission custody](recovery-submission-custody.md) for the shared evidence rules, deliberate fault-behavior change, compatibility limits and validation scope.
