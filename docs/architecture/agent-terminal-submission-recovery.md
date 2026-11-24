# Recover rejected Agent terminal submission

An Agent can finish its provider and Tool work yet fail to admit the terminal persistence work to its execution mechanism. The Agent still owns the accepted job, but it has no encoded terminal proposal to replay. G3b-3 adds explicit first-submission recovery to the same retained Agent operation while keeping captured-write retry separate.

For example, a research Agent calculates `retained answer`, then the worker queue rejects the terminal submission before accepting a handle or running its block. Once capacity becomes available, the application may explicitly authorize submission of that retained terminal command. Provider and Tool work remain finished; validation and encoding run for the first time.

The baseline is applied G3b-2 `b88eeb55cb1d9a888cc65ac1cdb75d2b1d8398a5`. This document describes the G3b-3 candidate; exact acceptance results belong to the delivery evidence. Contract concept v55 and foundation v48 remain the architecture references. The [G3b-2 recovery contract](agent-terminal-recovery.md) continues to define original-owner identity, observation, physical completion, application, release and shutdown custody.

## Require positive non-admission evidence

The original owner may authorize first submission only when the execution mechanism positively proves that the prior submission was not admitted. The owner must also have no returned task handle and no observed worker entry. A missing handle, an exception message or an exception class alone cannot establish that proof.

For example, the built-in OffloadPool can report a rejected enqueue through its explicit rejection callback. A custom backend that merely raises the same BackpressureError without that callback supplies no admission proof and leaves `submission_state` unknown.

A returned handle consumes first-submission permission even when its worker is still queued, is cancelled before entry, times out or loses its completion notification. An entered worker also consumes permission regardless of whether it produced complete persistence evidence. Neither case can be submitted again through this new operation. The owner consumes its permission before attempting resubmission; another mechanism-proven rejection can establish fresh `not_admitted` evidence.

This is an admission fact about terminal work, not a claim that the accepted Agent job was rejected. Its provider and Tool effects may already exist, and its job responsibility remains retained.

## Expose a distinct public operation and a fact

Applications need separate permissions for first terminal-work submission and replay of an already encoded save. The public result exposes the mechanism's admission fact so applications do not parse error strings to decide which request to make. The original owner revalidates current authority before every request.

For example, an earlier receipt can say `not_admitted` while another caller subsequently obtains admission. Retrying with the old capability must observe or refuse according to the current operation; the old receipt cannot authorize a second worker.

| Public surface | Meaning |
| --- | --- |
| `retry_terminal_submission_async(recovery:)` | Fresh TaskResult for explicit first terminal-work submission after positive non-admission proof. |
| `retry_terminal_submission(recovery:)` | Same operation, waited on a host thread; EventLoop blocking is rejected before submission. |
| `TerminalRecoveryResult#submission_state` | Immutable fact: `not_admitted`, `admitted` or `unknown`. |
| `not_admitted` | Mechanism-proven non-admission and no contradictory handle or worker-start fact. It can justify a new request only after the owner rechecks its present state. |
| `admitted` | A handle or worker entry established admission. First submission cannot be repeated, including when the accepted worker never started. |
| `unknown` | No usable positive admission decision; this is the default when facts are unavailable. It grants no first-submission permission. |

The existing capability, recovery error and result types are reused. Result fields for persistence outcome, live application and ownership remain independent. A non-admitted attempt has no captured pre/post persistence disposition; it remains unavailable with pending application and retained ownership. The result constructor rejects a `not_admitted` / `confirmed_pre` or `confirmed_post` contradiction.

Wrong capability types and another Agent incarnation's capability are rejected before I/O, as with existing recovery methods. The caller cannot select a replacement Store, Runtime or Agent. Resolved capabilities still return their retained receipt without new work. The source observation stays closed and its old event/stream listener is not replayed.

## Preserve the existing retry guarantees

Each recovery operation has a bounded, distinct authority. Readback only classifies and applies existing facts. Captured-save retry writes the already encoded bytes and records. First-submission recovery may perform the terminal validation and encoding that has never been admitted, but it must not repeat provider, Tool or other business work.

For example, `retry_terminal` still returns unavailable when no complete proposal exists. It does not silently call the new submission operation. Conversely, once a submission was accepted and failed during validation or encoding, this new method cannot restart it merely because no complete proof was produced.

| Operation | May run validation/encoding? | May write? | Required authority |
| --- | --- | --- | --- |
| `reconcile_terminal[_async]` | No | No | Retained complete proof or conclusive original worker result. |
| `retry_terminal[_async]` | No | Exact captured bytes and records only | Full guarded pre-state comparison, or recognize an already committed post-state. |
| `retry_terminal_submission[_async]` | First run only | First terminal save | Positive mechanism rejection proof with no admitted handle or observed worker entry. |

If a newly admitted submission later produces complete proof but loses its result, the existing readback/save-retry operations can handle that proof. It does not regain first-submission permission. A failure after admission but before full capture remains retained and unavailable for this first-submission operation. This stage intentionally does not add general encoder retry.

## Keep normal application behavior unchanged

The added operation does not require normal callers to change their code. Normal compatibility is evaluated with the same inputs, adapter, public invocation, saved-result observation and cleanup in both checkouts. Fault recovery is a separate intentional behavior change.

For example, a deterministic local provider returns the structured answer `ordinary answer` once. The complete function below invokes and observes it identically before and after the change; measurement records output, transcript, revisions, journal shape and physical completion.

<table>
<thead><tr><th>G3b-2 baseline</th><th>G3b-3 candidate</th></tr></thead>
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

The following shared setup precedes either function. It defines the Agent and deterministic adapter and installs no private recovery hook.

For example, changing only the framework checkout with this same setup avoids confounding normal compatibility with a different provider or application policy.

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

The shared measurement and driver below follow either function. They read private persistence records only as test evidence and shut down the normal-path Runtime after reporting. They are not hidden recovery policy.

For example, the functional report omits random IDs and timestamps while retaining exact provider count and execution/journal revisions. Set `G3_NORMAL_REPORT` to the report path and execute with the checkout's bundled dependencies.

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

The unchanged complete source was executed against the applied baseline and the candidate. Its normalized functional JSON matched exactly, including one provider call and logical/physical source completion. The source, reports and checkout provenance are included in the delivery evidence; the comparison covers this deterministic local normal path.

## Add explicit application permission for rejected submission

An application can authorize first submission separately from a captured save retry and retain unresolved responsibility when either request cannot proceed. Phronomy prevents duplicate terminal workers and business replay; it does not choose an application's retry schedule or escalation policy.

For example, the baseline function below can observe or save captured records but cannot recover a positively rejected terminal submission. The new function adds a separate `retry_submission` permission, checks the immutable admission fact, and makes at most one new submission request. The existing `retry_save` permission retains its distinct meaning.

<table>
<thead><tr><th>G3b-2: captured-save recovery</th><th>G3b-3: explicit submission permission</th></tr></thead>
<tbody><tr><td><pre lang="ruby"># frozen_string_literal: true

require &quot;phronomy&quot;

# The caller owns this Agent and its Runtime, and explicitly chooses whether a
# confirmed pre-state may be saved again. No provider or Tool is started here
# after the initial invocation. Pending recovery is returned to that owner.
def run_recoverable_request(agent:, input:, retry_save: false)
  result = agent.invoke(input)
  {state: :completed, result: result}.freeze
rescue Phronomy::Agent::TerminalRecoveryError =&gt; failure
  recovery = failure.recovery
  receipt = agent.reconcile_terminal(recovery: recovery)
  if retry_save &amp;&amp; receipt.outcome == :confirmed_pre
    receipt = agent.retry_terminal(recovery: recovery)
  end
  if receipt.outcome == :confirmed_post &amp;&amp; receipt.application_state == :applied &amp;&amp;
      receipt.ownership_state == :released &amp;&amp; receipt.execution
    {state: :observed, execution: receipt.execution.to_result,
     recovery: recovery, receipt: receipt}.freeze
  else
    {state: :recovery_pending, recovery: recovery, receipt: receipt}.freeze
  end
end</pre></td><td><pre lang="ruby"># frozen_string_literal: true

require &quot;phronomy&quot;

# The caller owns the Agent and Runtime. Each permission authorizes a different
# bounded operation: first terminal-work submission or captured-byte save retry.
# Pending responsibility and its newest receipt are returned to that caller.
def run_submission_recoverable_request(agent:, input:, retry_submission: false, retry_save: false)
  result = agent.invoke(input)
  {state: :completed, result: result}.freeze
rescue Phronomy::Agent::TerminalRecoveryError =&gt; failure
  recovery = failure.recovery
  receipt = agent.reconcile_terminal(recovery: recovery)
  if retry_submission &amp;&amp; receipt.submission_state == :not_admitted
    receipt = agent.retry_terminal_submission(recovery: recovery)
  end
  if retry_save &amp;&amp; receipt.outcome == :confirmed_pre
    receipt = agent.retry_terminal(recovery: recovery)
  end
  if receipt.outcome == :confirmed_post &amp;&amp; receipt.application_state == :applied &amp;&amp;
      receipt.ownership_state == :released &amp;&amp; receipt.execution
    {state: :observed, execution: receipt.execution.to_result,
     recovery: recovery, receipt: receipt}.freeze
  else
    {state: :recovery_pending, recovery: recovery, receipt: receipt}.freeze
  end
end</pre></td></tr></tbody>
</table>

These complete functions require an already created Agent and a host thread; the caller owns the Agent and Runtime. Their names identify the old recovery helper and the extended helper. Both permissions default to false. The new branch intentionally changes only recovery behavior for positive non-admission, so this is not an equivalence claim for that fault.

The helper returns `recovery_pending` with the capability and newest receipt when unresolved. It does not loop, create another Runtime, unload a busy Agent or label a saved failed/cancelled job as successful. A recovered `observed` result is a durable execution observation whose status the application must inspect. Subsequent uncertain saves may require a later explicit readback; the helper does not hide that extra decision.

Applications no longer need to inspect error strings or reach into private submission machinery. They still choose whether first validation/encoding and saving are permitted, whether captured bytes may be saved again, and how to keep or escalate unresolved responsibility.

## Serialize authority and observations

The original retained operation owns the one physical lane and admission decision. Fresh observation requests may join an accepted same-kind attempt, but they cannot create another submission. Cancellation of an observer does not revoke admitted work or restore consumed permission.

For example, two simultaneous first-submission requests after a queue rejection share one admitted terminal worker. If one observer cancels, the other still receives its receipt. A concurrent readback or captured-write retry does not change the submission's kind and cannot start another physical attempt.

Late or duplicate signals must identify their exact physical attempt. A stale signal from the rejected initial attempt cannot mark a later admitted worker complete, misclassify its result or release its owner. A rejected resubmission can reestablish `not_admitted`; any accepted handle remains consumed even if its block never enters. Repeated resolved requests return only the retained receipt.

Admission remains local to the original running or draining Runtime. Stopped-owner transfer and process-crash recovery remain outside scope. Shutdown cannot report complete cleanup while accepted physical work or unresolved responsibility remains.

## Keep mechanism proof and persistence authority separate

The mechanism's non-admission proof is a narrow statement that no submitted block can execute. Persistence still owns transaction and guard semantics, and the Agent owns its terminal command, result interpretation and release decision. Rejection notification does not authorize a backend read/write or classify a saved job.

For example, a supported execution backend emits its rejection callback only on a path where enqueue failed and no accepted task exists. A custom backend that cannot supply that guarantee leaves the operation unknown. Once a first save runs, its later reconciliation still requires settled backend transactions and authoritative read ordering; worker completion alone does not prove those remote facts.

No new manager or second responsibility registry is introduced. The existing Agent terminal operation stores the admission fact and physical attempt; the existing execution mechanism provides the proof. Workflow's confirmed-pre release policy and Agent's retained-active-job policy stay separate. The optional mechanism capability is needed only for positive rejection proof. A custom submitter opts in with `supports_submission_rejection? == true` and a `submit` method accepting `on_rejected:`; the callback must truthfully report synchronous refusal before any accepted work exists. A legacy custom backend with a fixed-keyword `submit` can still run ordinary work; the binding must not pass an unsupported rejection keyword or retry a failed call to discover support. A failure without that capability remains unknown. This preserves the covered ordinary-call contract, not a claim of compatibility with every custom backend.

## Verify the bounded extension

Acceptance must distinguish rejection before admission from accepted-but-queued work and failure after entry. It must also show that existing byte-only retry and original-owner release remain unchanged. Models and tests cover their explicit premises, not arbitrary backend implementations.

For example, a test should inject the same exception both with and without a valid rejection callback. Only the positively proven case may start the first terminal worker later; the other must remain unavailable without validation or encoding.

Required scenarios include normal compatibility, original observer failure with retained custody, first known rejection, unknown rejection, contradictory callback/start or callback/handle facts, repeated mechanism rejection, queued acceptance followed by cancellation/timeout, same-kind observer joining, mixed-kind refusal, stale notifications, commit/reply loss after first submission, failure before full capture after admission, closed-listener preservation, and incomplete shutdown. Provider/Tool counters must remain unchanged; validation/encoding counters can advance only for the first admitted terminal work.

The public snapshot adds two Agent methods, their inherited Orchestrator methods and one result reader. No existing method is removed. RBS, annotations, complete changed-file English checks, both canonical Contract diagrams, source dependencies, model results and actual bundle application remain delivery checks. The final validation report records actual counts and limits; no external database/LLM or distributed recovery acceptance is implied.

The exact source functions displayed above were also executed through nine tagged application examples, all passing. The fixture calls the real Runtime and persistence implementation. For rejected submission, it saturates the real OffloadPool, then releases capacity before the application decides whether to submit again. No new recovery API is mocked.

| Executed application case | Observed result |
| --- | --- |
| Unchanged complete normal function | Baseline/candidate functional JSON equal; one provider call and physical completion. |
| Recovery helper without a fault | Ordinary result and one normal completion event. |
| Committed save with lost reply | Confirmed post-state, application/release complete, no old completion event replay. |
| Rolled-back save without save permission | Confirmed pre-state, active job and responsibility retained. |
| Rolled-back save with explicit save permission | Captured save completes; provider remains called once. |
| Saved failed job | Recovery succeeds while the saved execution remains failed. |
| Proven rejected terminal submission with permission | First terminal worker runs once; two original provider calls and one Tool call are not replayed. |
| Proven rejection without permission | Not admitted; no terminal committer or encoder runs; responsibility remains retained. |
| Custom wrapper loses an admitted handle | Admission remains unknown while queued; no second worker is submitted despite application permission. |

These application examples complement the acceptance tests and model checks. They do not establish support for arbitrary providers, remote storage transactions, crash recovery or every possible application policy.
