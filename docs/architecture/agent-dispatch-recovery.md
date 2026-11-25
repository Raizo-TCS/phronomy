# Original-owner Agent dispatch preparation recovery

G3c retains pre-dispatch preparation across an uncertain save or a rejected setup-failure notification. The Agent owns the execution and its next transition; persistence establishes whether the captured change was saved; the Runtime accounts for physical work and serializes application by the same owner. Caller observation, saved permission and actual external dispatch remain separate facts.

For example, a report Agent has already read a Tool result and prepares the next Provider input. The dispatch-barrier transaction commits, but its response and immediate readback are unavailable. The same live Agent needs a way to establish that saved fact and continue the original input. Calling `invoke` again or rebuilding Provider preparation could repeat the report read, application hooks or context Policy.

Baseline: G3a2 `fba34a0ed4c98da94bfeaad4946dfee234f4b0e0`. This document describes the G3c implementation candidate. Contract concept v55 and foundation v48 identify the responsible boundaries; the delivery evidence records the final source, architecture review and validation results. Same-process failed-Runtime management remains a separate completion group.

## Keep a captured preparation and an external effect separate

The retained preparation contains the original input and the complete before/after save evidence, tied to its execution, session and operation identities. A successful readback may establish saved permission, but cannot establish whether an external request was admitted or completed. Only an original continuation whose first dispatch is still authorized may advance.

For example, a Tool batch with a saved dispatch record must not be regenerated from a later conversation snapshot. If any corresponding Tool dispatch is already admitted or uncertain, its external outcome needs the existing external-outcome recovery contract; this API does not infer that outcome by invoking the Tool again.

| Responsibility | Owner and evidence | Not implied by success |
| --- | --- | --- |
| Caller observation | One original or later `TaskResult` and its received result/error | Saved outcome, worker termination or release of the execution |
| Barrier persistence | Complete root, execution, journal, content and cancellation evidence under the original Store guard | Owner application or external dispatch |
| Original continuation | Original Agent, exact live session and captured prepared input or batch | Provider/Tool success after continuation admission |
| Physical work | Original preparation and each explicit recovery worker | Whole Agent job completion |
| External outcome | Existing Provider/Tool execution and recovery contracts | Permission to replay because a barrier was saved |

A confirmed pre-state remains retained. The application may explicitly request a guarded retry of the complete captured write proposal. That retry neither reruns preparation hooks/Policy nor reconstructs the input from mutable live state. A missing or incomplete proposal cannot be repaired by repeating preparation through this API.

For example, after a rolled-back barrier, `reconcile_dispatch` reports `confirmed_pre` without invoking the Tool. A later explicit `retry_dispatch` can save the held proposal when the original preconditions still match. If cancellation or another writer changed those preconditions, the retry must report unresolved responsibility rather than apply stale writes.

## Observe through the original Agent

A process-local recovery capability identifies one operation held by one exact Agent incarnation. Public identifiers are diagnostic; neither a copied handle nor another Agent with the same durable ID is recovery authority. Each asynchronous method returns a fresh observation, and its synchronous counterpart waits only on a permitted host thread.

For example, an `invoke_async` observation can end with `DispatchRecoveryError`. A later reconciliation can resume the same execution while that original observation remains failed. The new receipt supplies a different execution observation; it does not revive the old invocation or create a replacement Agent.

| Public method or value | Contract |
| --- | --- |
| `pending_dispatch_recovery(execution_id:)` | Local lookup on the exact Agent's existing registry. Requires a nonempty String; performs no I/O and creates no Runtime. |
| `reconcile_dispatch_async(recovery:)` / `reconcile_dispatch(recovery:)` | Read the barrier and, when all guards permit, apply confirmed post-state and continue the original work. Does not retry writes. |
| `retry_dispatch_async(recovery:)` / `retry_dispatch(recovery:)` | Explicit guarded retry of the already captured barrier writes, followed by the same application/continuation checks. |
| `DispatchRecovery` | Frozen, privately constructed capability with `agent_id`, `execution_id`, `recovery_id`, and `dispatch_kind` (`provider` or `tool`). |
| `DispatchRecoveryError` | Code `agent.dispatch_recovery`; preserves the capability, the original error and the immediate cause. It is not a saved job-failure verdict. |

After a stream observation fails with retained dispatch responsibility, its original stream callback is closed and is not resumed by reconciliation. The recovered execution task observes the aggregate result; this API does not create a replacement stream subscriber. The configured approval listener remains a separate application policy callback.

For example, a stream caller can receive some earlier events and then a dispatch recovery error. Later reconciliation may finish the same execution, but does not replay or deliver later events through that failed stream callback.

Cancelling a recovery observation does not cancel its retained work. The existing execution cancellation API is the control operation. Cancellation is checked again before continuation dispatch; restoring a saved barrier never overrides authoritative cancellation. Resolution removes pending lookup, but a held capability can still report its final receipt without redispatch.

For example, a caller can time out while awaiting a recovery read, retain the Agent and capability, and explicitly observe later. It must not submit another report request merely because that observation timed out. Likewise, `physical_complete?` on the recovery receipt does not mean the resumed report Tool has stopped.

## Read the receipt as evidence rather than a business result

The immutable receipt separates saved outcome, owner application, continuation handoff and preparation/recovery worker completion. Only the execution observation reports the continuing job's result. Resolving the barrier obligation leaves that same job under its ordinary ownership and release conditions.

For example, confirmed post-state can be applied while continuation remains pending after a scheduling failure. A subsequent receipt can report `resumed` while the Provider is still running. Cancellation or a post-save input materialization error can instead send the original FSM through its existing terminal path without making a Provider call.

| Reader | Meaning |
| --- | --- |
| `outcome` | `confirmed_pre`, `confirmed_post`, `not_prepared`, `unresolved` or `unavailable`. `not_prepared` requires positive evidence that preparation ended before entering the barrier; missing proof alone is insufficient. |
| `application_state` | `pending` or `applied` by the original Agent. Confirmed post-state or positively established pre-barrier failure can be applied; confirmed pre-state cannot. |
| `continuation_state` | `pending`, `resumed` or `stopped`. Resumed hands off a confirmed barrier continuation, including cancellation/error. Stopped hands off only a positively established pre-barrier failure notification. Neither proves whole-job termination or external success. |
| `physical_complete?` | Original preparation and recovery workers have stopped; continued business work may still be active. |
| `resolved?` | A confirmed barrier or positively established pre-barrier failure has been applied, preparation/recovery work is physically complete, and its resumed/stopped continuation has been handed off. |
| `revision` | The exact confirmed pre/post execution revision; nil for `not_prepared` and unclassified persistence. |
| `execution_task` | A fresh independent execution observation, available only after applied/resumed post-state or applied/stopped pre-barrier failure. It observes the same job, including its original setup error. |
| `error` | Recovery/read/application error. The continuing job's own error is observed through `execution_task`. |

A `not_prepared` receipt requires an observed preparation boundary: the barrier was never entered and the original worker physically ended, or the execution mechanism positively refused admission before a worker could begin. It does not classify storage rollback from missing evidence. Once the owner adopts that known failure, a rejected notification can leave application applied while continuation remains pending. Only the exact retained failure notification is redelivered; hooks, Policy, preparation and business dispatch are never repeated.

For example, an input hook fails before `ExecutionChange.perform`, and its `llm_setup_failed` notification is explicitly refused. Recovery can later deliver that same failure and return `not_prepared`/`stopped` with an execution observation of the original error. A barrier that may have started but left no complete proof must remain unresolved instead.

A confirmed pre-state cannot be marked applied or resumed. A saved post-state alone also cannot create an execution observer before the handoff. These restrictions keep the public value shape consistent with the retained owner protocol.

For example, constructing a receipt with `confirmed_pre` plus `resumed` is rejected. A valid resolved receipt can still contain an execution TaskResult that subsequently fails; that later failure does not rewrite the earlier persistence proof or falsely reopen the original caller's closed observation.

## Preserve the ordinary application

The ordinary report application has the same inputs, Provider/Tool effects, output, persistence and observation contract before and after G3c. Its adapter is deterministic and sends no network request; the Agent, Store and Runtime are real. The extra record reads in the function measure behavior and are not a proposed application API.

For example, both versions read one report Tool and return `report ready` after two Provider completions. Run one copy of the shared setup, either complete function below, and the shared driver. The delivery compares actual baseline and candidate reports; the source listings are tied to the executed helper.

### Shared application setup

The fixture defines the report Tool, the Agent that exposes it, and the Provider adapter used by both versions.

For example, the first Provider response requests `read_dispatch_report`; the second returns the final report text. The Tool counter detects any duplicate effect.

<!-- example: shared-setup -->
```ruby
# frozen_string_literal: true

require "phronomy"
require "json"

class G3cReportTool < Phronomy::Tool::Base
  tool_name "read_dispatch_report"
  description "Read one report through a deterministic fixture"
  class << self
    attr_accessor :calls
  end

  def execute
    self.class.calls += 1
    "report content"
  end
end

class G3cReportAgent < Phronomy::Agent::Base
  agent_definition id: "dispatch-report", version: 1
  model "offline-model"
  tools G3cReportTool => nil
end

class G3cReportAdapter < Phronomy::LLMAdapter::Base
  attr_reader :calls

  def initialize
    @calls = 0
  end

  def perform_complete(_request, cancellation_token:)
    cancellation_token&.raise_if_cancelled!
    @calls += 1
    if @calls == 1
      Phronomy::LLMAdapter::Response.new(tool_calls: [
        Phronomy::Tool::CallRequest.new(id: "report-read", name: "read_dispatch_report", arguments: {})
      ], finish_reason: :tool_calls)
    else
      Phronomy::LLMAdapter::Response.new(content: "report ready", finish_reason: :stop)
    end
  end
end
```

### Complete before-and-after functions

The same function starts one invocation, observes its result and records the saved execution and call counts. The comparison is equivalent only for the ordinary successful path; the intended fault-path changes are listed separately below.

For example, neither side requires application-managed dispatch identity or Store reconciliation when no failure occurs.

<table>
<thead><tr><th>Before: G3a2 baseline</th><th>After: G3c candidate</th></tr></thead>
<tbody><tr><td>
<!-- example: normal-before -->
<pre><code># The ordinary application requests one report and observes its final result.
# The adapter is deterministic; the Agent, Store and Runtime are real.
def run_dispatch_report
  G3cReportTool.calls = 0
  adapter = G3cReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  store = Phronomy::PersistenceComposition.in_memory.agent
  agent = G3cReportAgent.create(agent_id: &quot;dispatch-report&quot;, persistence: store)
  invocation = agent.invoke_async(&quot;Read the report&quot;)
  result = invocation.wait_result(timeout: 5)
  execution = store.executions.load(result.fetch(:execution_id))
  {
    output: result.fetch(:output), execution_status: execution.status,
    execution_revision: execution.execution_revision,
    agent_revision: agent.agent_root.agent_revision,
    root_status: agent.agent_root.lifecycle_status,
    provider_calls: adapter.calls, tool_calls: G3cReportTool.calls,
    invocation_logical_complete: invocation.done?,
    invocation_physical_complete: invocation.physical_complete?
  }
end</code></pre>
</td><td>
<!-- example: normal-after -->
<pre><code># The ordinary application requests one report and observes its final result.
# The adapter is deterministic; the Agent, Store and Runtime are real.
def run_dispatch_report
  G3cReportTool.calls = 0
  adapter = G3cReportAdapter.new
  Phronomy.configure { |configuration| configuration.llm_adapter = adapter }
  store = Phronomy::PersistenceComposition.in_memory.agent
  agent = G3cReportAgent.create(agent_id: &quot;dispatch-report&quot;, persistence: store)
  invocation = agent.invoke_async(&quot;Read the report&quot;)
  result = invocation.wait_result(timeout: 5)
  execution = store.executions.load(result.fetch(:execution_id))
  {
    output: result.fetch(:output), execution_status: execution.status,
    execution_revision: execution.execution_revision,
    agent_revision: agent.agent_root.agent_revision,
    root_status: agent.agent_root.lifecycle_status,
    provider_calls: adapter.calls, tool_calls: G3cReportTool.calls,
    invocation_logical_complete: invocation.done?,
    invocation_physical_complete: invocation.physical_complete?
  }
end</code></pre>
</td></tr></tbody>
</table>

### Shared measurement driver

The driver validates the business output and call counts, writes the measured report and records the loaded source path. The caller selects output paths with `G3C_NORMAL_REPORT` and `G3C_NORMAL_SOURCE`.

For example, the baseline report must identify `g3c-baseline` as its loaded gem location, while the candidate report identifies the changed checkout. Equal hard-coded expected JSON would not establish that comparison.

<!-- example: normal-driver -->
```ruby
if $PROGRAM_NAME == __FILE__
  begin
    report = run_dispatch_report
    raise "Unexpected output" unless report[:output] == "report ready"
    raise "Unexpected business replay" unless report[:provider_calls] == 2 && report[:tool_calls] == 1
    File.write(ENV.fetch("G3C_NORMAL_REPORT"), JSON.pretty_generate(report) + "\n")
    File.write(ENV.fetch("G3C_NORMAL_SOURCE"), JSON.pretty_generate({
      application: method(:run_dispatch_report).source_location,
      preparation: Phronomy::Agent::DispatchPreparation.instance_method(:prepare_provider).source_location,
      gem: Gem.loaded_specs.fetch("phronomy").full_gem_path
    }) + "\n")
  ensure
    Phronomy.reset_runtime!
  end
end
```

## Add recovery policy only to the uncertain path

The complete helper below starts an invocation once and handles its retained dispatch error. It performs one reconciliation and, only with explicit caller policy, one guarded retry for confirmed pre-state. A pending result preserves the capability for a later observation; it is not permission to invoke the original request again.

For example, a read-only report application can choose `retry_confirmed_pre: true` for the captured barrier writes. A caller that needs separate approval for each write attempt leaves the default false and obtains `recovery_pending`. Neither choice retries the report Tool or Provider operation.

<!-- example: recovery-handler -->
```ruby
# frozen_string_literal: true

require "phronomy"

# Observe one retained obligation. The caller chooses whether one confirmed
# pre-state may receive an explicit persistence-only retry. There is no loop,
# replacement Agent, provider retry, Tool retry or repeated preparation here.
def observe_dispatch_recovery(agent:, recovery:, retry_confirmed_pre: false)
  receipt = agent.reconcile_dispatch(recovery: recovery)
  if retry_confirmed_pre && receipt.outcome == :confirmed_pre && !receipt.resolved?
    receipt = agent.retry_dispatch(recovery: recovery)
  end
  if receipt.resolved?
    {state: receipt.continuation_state, recovery: recovery, receipt: receipt,
     execution_task: receipt.execution_task}.freeze
  else
    {state: :recovery_pending, recovery: recovery, receipt: receipt}.freeze
  end
end

# Start once, then observe the same execution. After recovery_pending, retain
# the Agent and capability and call observe_dispatch_recovery again when useful;
# do not call this start helper again for the unresolved original request.
def invoke_with_dispatch_recovery(agent:, input:, retry_confirmed_pre: false)
  result = agent.invoke(input)
  {state: :completed, result: result}.freeze
rescue Phronomy::Agent::DispatchRecoveryError => failure
  observe_dispatch_recovery(agent: agent, recovery: failure.recovery,
    retry_confirmed_pre: retry_confirmed_pre)
end
```

The application retains its Agent and unresolved capability, decides when another observation is useful and whether to permit the persistence-only retry, and observes any returned execution task. Phronomy owns the complete proof, original continuation identity, worker accounting and exactly one local application decision. This API does not remove application policy or promise exactly-once external effects.

For example, after `resumed` or `stopped`, call `execution_task.wait_result` to receive the same job's ordinary result/error. The helper uses the actual continuation state rather than labelling a stopped setup as resumed work. After `recovery_pending`, call `observe_dispatch_recovery` with the same capability. Calling `invoke_with_dispatch_recovery` again would start another request and is deliberately not the pending path.

| Trigger | G3a2 baseline | G3c intentional change |
| --- | --- | --- |
| Ordinary success | Original invoke/stream result and effects | Preserved ordinary contract |
| Saved barrier, lost response and unavailable immediate readback | Admission retained as recovery-required without a usable dispatch recovery API; original observation may remain pending | Typed retained error and independent explicit observation; confirmed proof can advance the original continuation once |
| Confirmed rollback/pre-state | No captured-proposal public dispatch retry | Confirmed pre-state remains pending; explicit retry writes only the original captured proposal under guards |
| Read unavailable or conflicting state | Original failure cannot classify persistence | Explicit unavailable/unresolved receipt with retained responsibility |
| Ready delivery rejected or delayed | Completion does not by itself repair the original owner | Physical facts and captured proof remain available to an explicit later recovery observation |
| Positively known pre-barrier failure and rejected setup notification | A failed setup notification may leave the original FSM awaiting progress | `not_prepared` and retained failure notification; successful handoff reports `stopped` without repeating preparation |
| Original Runtime stopped | A different Runtime cannot repair its local owner safely | Unavailable/retained responsibility; no claim of successful transfer or release |

## Preserve symmetry and domain responsibility

The new operations follow existing retained-owner recovery naming, identity validation, observation isolation and host-thread waiting. Differences reflect the continuation being recovered: terminal proof can release a terminal job, approval proof can restore a human wait, and dispatch proof can permit the original next step.

For example, approval confirmed pre-state can restore the same approval request without rewriting it. Dispatch confirmed pre-state has no human wait to restore, so it remains retained until the application explicitly permits a guarded retry. The terminal submission retry is not a generic template for repeating Provider preparation.

| Aspect | Terminal recovery | Approval recovery | Dispatch recovery decision |
| --- | --- | --- | --- |
| Local capability and lookup | Original owner, process-local | Original owner, process-local | Adopt the same exact-incarnation authority |
| Sync/async observation | `reconcile_terminal` pair | `reconcile_approval` pair | Adopt `reconcile_dispatch` pair |
| Captured-write retry | Explicit `retry_terminal` pair | No automatic repeated human decision | Adopt explicit `retry_dispatch` pair |
| Initial submission retry | Separate mechanism proof and API | Original approval wait can be restored after proved non-admission | Defer; no preparation rerun. Positively established pre-barrier failure can redeliver only its exact failed-setup notification |
| Confirmed pre-state | Retain terminal obligation | Restore original approval wait | Retain captured barrier; no invented restored state |
| Continued work observation | Terminal execution observation | Fresh execution task after resumed decision | Fresh execution task after resumed barrier or stopped pre-barrier failure |
| Release | Requires terminal and physical conditions | Approval resolution does not release the job | Dispatch resolution does not release the job |
| Cross-process takeover | Not provided by the capability | Not provided by the capability | Not provided by the capability |

A unified public Job API and further generic owner extraction are not prerequisites. Domain-specific save authority, cancellation checks, continuation admission and release remain with their current owners; neutral physical completion facts can use the existing shared component.

For example, using a terminal helper that releases Agent admission after successful dispatch proof would lose an executing job's responsibility. Reusing `PhysicalAttempt` to record a stopped recovery worker preserves the domain boundary without adopting that incorrect release policy.

## Bound the supported recovery conditions

G3c retains the original live standalone Agent, its exact Store and captured preparation. Existing hosted, participant and reserved paths need their own applicability evidence and are not automatically granted takeover through this capability. A draining Runtime may process already retained work; full administration after Runtime failure remains a separate completion group.

For example, another Agent with the same execution identifier cannot use a copied `DispatchRecovery` to dispatch the prepared Tool. The original owner must still satisfy identity, session, revision, cancellation and non-dispatch conditions before it continues.

The Store must establish prior transaction settlement, authoritative ordered readback, guarded exclusion and atomicity. Physical worker termination or an InMemory fixture alone does not establish those assumptions for a remote database. Existing external-effect uncertainty remains separate, and missing evidence remains retained rather than guessed successful.

For example, a backend that can commit the old transaction after readback needs an ordering mechanism before a read can prove confirmed pre-state. Repeatedly reading until a convenient value appears is not that mechanism.

## Validate models, implementation and application separately

The finite [dispatch preparation model](../../spec/models/dispatch_preparation_recovery/README.md) tests explicit safety and conditional progress assumptions; real Runtime fault tests exercise the implementation; complete application comparisons check the public use case. The delivery records their exact scope instead of treating one category as proof of the others.

For example, a model mutation that permits two dispatches must fail its safety check. A real fault test must also lose the dispatch save response, delay or reject Ready delivery, obtain the held capability, and establish the observed Provider/Tool call counts and responsibility retention.

The delivery includes baseline reproductions, Provider/Tool pre/post/conflicting/unavailable evidence cases, observer and physical-work separation, duplicate/stale recovery requests, cancellation before dispatch and post-save materialization failure. It separately records unsupported or untested backend/ownership profiles. Passing the model does not constitute a refinement proof for all Ruby code or an exactly-once guarantee across external services.
