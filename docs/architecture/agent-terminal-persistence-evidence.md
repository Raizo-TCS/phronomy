# Agent terminal persistence evidence: private preparation stage

Agent terminal persistence needs to preserve what it intended to save before an
ambiguous transaction result can discard that proposal. This stage adds a private
value-based persistence path; it does not connect recovery to the original live
Agent owner. The default `ExecutionCoordinator` remains unchanged, and no public
Agent recovery API or shutdown correction is provided by this stage.

For example, an Agent can finish a provider request, prepare its terminal records,
and lose both the transaction response and the first authoritative read. A future
recovery owner needs that exact proposal to distinguish a committed result from a
rolled-back write. Re-running the provider or parsing its output again would
produce a new computation rather than establish the original persistence fact.

The implementation baseline is G2 commit
`802176d2afacf3d28f8ca03468ca970729ae8660`; the working branch is
`fix/agent-terminal-evidence`. G2's implemented
[Workflow terminal reconciliation](workflow-terminal-reconciliation.md) remains
a separate, domain-specific recovery contract. This document describes G3b-1,
not completion of G3b, G3, or the full lifecycle redesign.

## Responsibility and the retained proposal

The persistence helper preserves a completed proposal and classifies repository
evidence. A caller owns the lifetime of that value and any decision to use it.
Only the Agent execution owner can eventually apply a confirmed result to live
state, settle the original operation, and release its admission. Neither a
persistence classification nor the helper's return value grants that authority.

For example, a confirmed pre-state leaves the durable execution active. A helper
can prepare to persist the already-computed terminal outcome, but it cannot
declare that accepted job finished merely because the first write rolled back.
This differs from Workflow's existing known-terminal-save-failure disposition.

| Responsibility | This private stage | Still outside this stage |
| --- | --- | --- |
| Capture | Complete eligible standalone terminal evidence, semantic Outcome, and referenced content bytes | A production owner that retains the evidence after the worker returns |
| Readback | Compare the retained proposal with an authoritative repository snapshot under the required guards | Live Agent state updates or original observer settlement |
| Save-only retry | Persist the retained proposal only when the exact pre-state still matches | Provider, Tool, parser, graph, or arbitrary business retries |
| Ownership | Preserve Agent's existing authority boundary | Admission release, original operation acknowledgement, or Runtime custody transfer |
| Public observation | Existing Agent methods remain in place | Recovery capability, pending lookup, independent recovery observers, or a new public result type |

`ExecutionChange` remains a single-use, thread-bound transaction operation. The
retained value must not keep its executable write closure, Agent, participant, or
original scope as a retry mechanism. A fresh permitted persistence operation
consumes the captured facts instead.

## Complete evidence includes content bytes

Evidence must describe every fact that the transaction can change or that guards
the proposed terminal transition. It must also retain the content necessary to
write that same proposal after rollback. Record references alone do not preserve
bytes whose insertion belonged to the rolled-back transaction.

For example, a structured result can create an output content object and a raw
provider-output object before saving execution and journal records that refer to
them. If the outer transaction rolls back, those new objects can disappear too.
Keeping the intended `result_ref` without its bytes cannot reconstruct the same
terminal save; calling the parser or provider again would change the operation.

| Evidence category | Why it is required |
| --- | --- |
| Agent root and execution | Check exact identities, revisions, lifecycle state, terminal fields, and referenced metadata |
| Journal suffix | Preserve exact record identities, sequence, payload references, and expected stream position |
| Extension and cancellation state | Reject a changed obligation even when root or execution revisions appear unchanged |
| Semantic Outcome | Preserve the already-computed result or failure for later owner application |
| Referenced content bytes | Recreate transaction-local content lost in rollback without recomputing output or runtime records |
| Detached error diagnostic | Preserve terminal failure meaning without retaining an arbitrary exception that may reference a live Agent |

The eligible scope is already-installed, active standalone terminal completion,
failure, or cancellation. Approval suspension, dispatch, preparation, participant-owned
transactions, extension-bound execution, and responsibility transfer need their
own evidence and ownership contracts. They must not silently enter this path.

## Private persistence operations

A caller may opt into evidence capture without changing the ordinary Agent
execution route. Capture, later classification, and a guarded save-only retry
are separate operations. No helper schedules retries or assumes ownership of the
original execution merely because the callback retained a value.

For example, a private test harness can retain an eligible proposal through
`on_evidence`, observe a transaction failure, and later read the same proposal.
The default coordinator supplies no such callback, so an ordinary application
does not gain this recovery behavior just by upgrading to this stage.

| Private operation | Contract |
| --- | --- |
| `ExecutionOutcomeCommitter#commit_outcome(operation, on_evidence: nil)` | The default path captures no evidence. An eligible opt-in call gives its callback a complete value after the original perform/readback path finishes, including a complete proposal from a rolled-back attempt. |
| `TerminalPersistenceEvidence#reconcile(persistence:, original_error: nil)` | Reads and classifies the complete retained proof under the original Store's coordinator and Agent guard. It performs no writes or live owner application. |
| `TerminalPersistenceEvidence#retry(persistence:, original_error: nil)` | Rechecks the complete proof in a fresh outer transaction. It writes the retained content and records only for an exact pre-state; an already committed state causes no duplicate write. Conflicting state is refused. |

The frozen evidence exposes `before`, `after`, `outcome`, `content_writes`,
`attempt_id`, `agent_id`, and `execution_id`. Each captured content write has its
reference, bytes, and canonicalization version. The detached Outcome preserves
its type, root, execution, appended records, result, and `error_diagnostic`;
it does not retain the arbitrary terminal exception itself as live wiring.
The ordinary committer's existing Outcome and exception behavior remain separate.

Read and retry results expose `disposition` (`committed`, `not_committed`, or
`unknown`), `evidence`, `original_error`, and `read_error`. The original error is
supplied by the private caller, while a failed retry can supply that attempt's
error. An unavailable read and conflicting evidence both remain unknown; this is
not Workflow's public four-outcome result type. The evidence ID identifies the
captured proposal, not a managed registry entry or a new physical-attempt lane.

These are private signatures, not additions to the Stable/Beta public API
inventory. A private identity rejects a different Store before repository I/O,
even if its records have equal values. The caller must retain the evidence,
preserve any original error it needs, and satisfy prior-attempt settlement
conditions. Applications must not treat these helpers as a supported recovery
surface. Capture after the original worker path is not the future protocol that
retains custody before publishing uncertainty.

The collector runs synchronously and must retain the value before returning.
On an original persistence failure, a collector failure must not replace that
original failure. After a successful commit, collector failure propagates and
does not mean the commit rolled back. Neither case establishes that a production
owner has accepted custody; no default coordinator collector exists yet.

## Transaction and backend prerequisites

Classifying an original write as absent requires settled write semantics and an
authoritative read ordered after that settlement. Applying a retained proposal
requires a fresh outermost atomic scope with the same ordered Agent guards,
revision/CAS checks, and complete evidence comparison. A savepoint or local
worker return alone cannot establish these conditions.

For example, a remote database request can return a transport error while the
server still has a commit in flight. Even if the Ruby worker has exited and a
replica shows the old revision, a second write is not authorized. The adapter
must establish original-write settlement and the required authoritative ordering
before this helper's pre-state classification can be relied on.

Cancellation is part of the compared facts. If cancellation was recorded after
the proposal was captured, a later retry must refuse the changed pre-state rather
than persist an obsolete successful outcome. The helper does not reinterpret
that conflict as permission to release the Agent or manufacture a replacement
cancellation outcome.

The journal's actual head must also match the root's declared position. Extra
records beyond an otherwise matching captured suffix are conflicting evidence,
not permission to classify the proposal as committed or retry it.

Nested transaction use is rejected for the retained-evidence path. Successful
save-only retry must mean outermost commit, not temporary savepoint success.
An ambiguous retry result is classified from the same retained pre/post proof;
there is no automatic retry loop. Unsupported backend ordering remains outside
the guarantee, even if that adapter implements the repository method names.

## Public application comparison

Applications continue to use the existing invocation and observation methods.
The normal result shape, error handling, and ownership of application cleanup do
not become simpler in this private stage. The potential benefit is a future
same-owner recovery path that avoids replaying completed computation; that path
has not yet been connected.

For example, a service that invokes an Agent for a structured answer still calls
the same public method and reads the same result. Resuming a durable completed
execution remains a separate observation; it does not prove that the original
live owner has applied the result or released its admission.

The complete application function is identical before and after this private
stage. Both sides use the same configured fixture Agent, input, output schema,
timeout, and persistence. It retains the original task as well as the separate
resume observation. This is a normal-path comparison, not evidence that an
ambiguous terminal save can now recover its original live owner.

<table>
<thead><tr><th>Baseline public operation</th><th>Operation after G3b-1</th></tr></thead>
<tbody><tr><td><pre><code>def run_normal_application(persistence:)
  agent = G3NormalApplicationAgent.create(agent_id: &quot;g3-normal-agent&quot;, persistence: persistence)
  source_task = agent.invoke_async(&quot;ordinary question&quot;, output_schema: {
    type: &quot;object&quot;, properties: {answer: {type: &quot;string&quot;}},
    required: [&quot;answer&quot;], additionalProperties: false
  })
  source_result = source_task.wait_result(timeout: 5)
  observed_result = agent.resume(source_result.fetch(:execution_id))
  [agent, source_task, source_result, observed_result]
end
</code></pre></td><td><pre><code>def run_normal_application(persistence:)
  agent = G3NormalApplicationAgent.create(agent_id: &quot;g3-normal-agent&quot;, persistence: persistence)
  source_task = agent.invoke_async(&quot;ordinary question&quot;, output_schema: {
    type: &quot;object&quot;, properties: {answer: {type: &quot;string&quot;}},
    required: [&quot;answer&quot;], additionalProperties: false
  })
  source_result = source_task.wait_result(timeout: 5)
  observed_result = agent.resume(source_result.fetch(:execution_id))
  [agent, source_task, source_result, observed_result]
end
</code></pre></td></tr></tbody>
</table>

The following complete shared source supplies the deterministic adapter, Agent
class, dependencies, invocation, assertions, and Runtime cleanup. The
`functional_observation` helper reads private persistence/live-state records
solely to measure the comparison; it is not public application guidance or a
recovery API. Run it with the repository's bundle and `-Ilib`, and set
`G3_NORMAL_REPORT` to an output JSON path. Each comparison run uses a fresh
in-memory store and process. No sample installs the private evidence callback.

<details>
<summary>Complete shared setup, application function, measurement, and cleanup</summary>

```ruby
# frozen_string_literal: true

# Run from the repository root with its bundled dependencies. This deterministic
# fixture adapter performs no network request. The application operation uses
# public Agent APIs; G3b's private evidence callback is not installed. The separate
# measurement helper reads private persistence records solely as test evidence.
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

def run_normal_application(persistence:)
  agent = G3NormalApplicationAgent.create(agent_id: "g3-normal-agent", persistence: persistence)
  source_task = agent.invoke_async("ordinary question", output_schema: {
    type: "object", properties: {answer: {type: "string"}},
    required: ["answer"], additionalProperties: false
  })
  source_result = source_task.wait_result(timeout: 5)
  observed_result = agent.resume(source_result.fetch(:execution_id))
  [agent, source_task, source_result, observed_result]
end

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

</details>

The unchanged source was executed before and after the private change with the
real Agent and Runtime, an in-memory repository, and the deterministic provider
fixture. The functional result, transcript, durable revisions/status, and resumed
output matched exactly in the measured fields; generated execution IDs and record
timestamps are excluded, and usage is compared through `TokenUsage#to_h`.
Each run called the provider once, and its original
source task was both logically done and physically complete. This establishes
the tested normal-path behavior; it does not establish same-owner recovery from
an ambiguous save or acceptance of an external database or provider service.

## Workflow comparison and common implementation decision

Agent and Workflow can share rules about retained evidence, independent
observations, physical completion, and exact owner application. Their evidence
structures and the action permitted by a confirmed pre-state remain domain
decisions. Common invariants do not by themselves justify another manager.

For example, Workflow compares one terminal snapshot with an exact revision.
Agent compares root, execution, journal, cancellation, and referenced content;
its accepted durable execution may remain active after a rolled-back terminal
save. A generic pre-state handler that releases both owners would be incorrect.

| Comparison | Workflow G2 | Agent G3b-1 |
| --- | --- | --- |
| Persistence proposal | Exact revisioned snapshot | Multi-record terminal proposal plus referenced content and semantic Outcome |
| Confirmed post | Existing recovery owner may apply and release after its gates | Private classification only; owner integration remains pending |
| Confirmed pre | Existing known-save-failure disposition can end the segment | Active accepted execution remains; guarded save-only retry is a distinct remedy |
| Public observation | Local capability, lookup, sync/async reconciliation | Existing public API only |
| Lifetime | Captured running/draining Runtime retains unresolved responsibility | Private caller must retain the evidence; default coordinator does not |
| Shared mechanisms | Existing persistence comparison, results, physical completion, neutral custody | Existing atomic coordination, guarded records, comparison, and immutable values |

| Commonality criterion | Current assessment |
| --- | --- |
| Removed duplication | Proof comparison is reusable; complete proposal shape and terminal disposition differ. No cross-domain line reduction is established. |
| Connection and comprehension cost | A generic manager would need adapters for Agent's multi-record/content proposal and Workflow's segment outcome. Their cost is not justified yet. |
| Duplicate state management | Avoid a second registry mirroring the existing execution owner. This private value does not create a registry. |
| Shared defect corrections | Guarding immutable evidence and separating facts from release are shared rules. Domain-specific persistence and application corrections remain separate. |
| Total verification burden | Shared fault scenarios can help, but real Agent and Workflow owner tests remain necessary. Additional adapters would also need tests. |
| Dependency and execution cost | Keep persistence interpretation and owner release in their domains. No new generic manager, Engine-to-Agent dependency, or performance benefit is claimed. |

The current decision is to retain the existing neutral primitives and add only
the Agent-specific evidence path. Reconsider smaller common components after a
real Agent owner is connected and both domains can be compared at the same
capability level.

## Next lifecycle stage and acceptance boundary

G3b-2 must connect persistence evidence to the exact original execution owner.
That owner must retain responsibility before uncertainty is published, serialize
physical attempts, apply confirmed facts once, and define observation and
shutdown behavior. Those are required future changes, not implied behavior of
the evidence value.

For example, after a lost terminal-save response, a future recovery request may
read a committed outcome and deliver it to the original owner. It must validate
Agent, execution, session, recovery generation, and required physical completion
before settling the original operation or releasing admission. A durable result
visible through `resume` alone does not meet that acceptance condition.

The future scope must cover cancelled or discarded observers, rejected and lost
deliveries, concurrent recovery requests, unknown retry outcomes, changed
cancellation evidence, stopped owners, and incomplete cleanup. Public method
names, receipt lifetime, supported Runtime states, and post-stop transfer must be
decided explicitly. This stage does not claim crash recovery, external database
acceptance, or that the reproduced original-owner and shutdown gaps are fixed.
