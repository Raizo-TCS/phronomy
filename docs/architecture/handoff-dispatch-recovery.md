# Handoff dispatch recovery and exact turn continuation

Handoff owns the route between Agent executions. Agent owns the retained save that permits its next Provider or Tool dispatch. This change connects Handoff routing evidence to the existing Agent recovery owner and lets the application continue the same saved Handoff chain after that Agent observation settles.

For example, a case Source performs one lookup, then loses the response to the save preceding its next Provider call. Reconciliation confirms the captured save, or the caller explicitly retries a confirmed pre-state. The Source then finishes directly or transfers responsibility to the exact reserved Target. The Runner follows that same case to its saved result without issuing the lookup again.

Baseline: `5bfc188ed7516a7464242668fa38abfecb366427`. The candidate uses the same common `RetainedAttempts` and `AttemptCompletion` through the existing Agent dispatch owner. Contract concept version 55 and foundation version 48 keep MultiAgent routing authority separate from Agent execution evidence and common attempt mechanics. No new mutex, executor or generic recovery coordinator is introduced.

## Behavioral scope of the comparison

The application supplies the graph, configuration and explicit save-retry policy. The framework supplies exact execution identity, captured persistence proof, retained observation and route continuation. The ordinary success path is equivalent within this application; recovery from the diagnosed uncertain barrier intentionally changes behavior.

For example, both ordinary versions below run one lookup and complete the case with two Provider calls, or three when the Source transfers to the Target. On the old uncertain-save path, the original owner can remain held without a public dispatch recovery capability. A second `invoke` after completion creates a new turn, so it is not a general recovery operation.

| Boundary | Applied baseline | Candidate |
| --- | --- | --- |
| Ordinary Source and Target execution | Existing `invoke` path | Same input, business calls, normal result and error policy |
| Captured follow-up Provider or Tool save becomes uncertain | Handoff does not supply retained dispatch evidence | Original call raises `Agent::DispatchRecoveryError`; the original Agent retains the capability |
| Proven pre-state | No Handoff retained dispatch retry route | Application may choose the existing `retry_dispatch`; no implicit write |
| Proven post-state | No Handoff retained continuation route | Existing Agent owner grants the captured continuation once under current authority |
| Continue the Handoff chain | `invoke` may start another turn | `resume(execution_id, config: {})` follows only the requested chain |
| Initial preparation before the ordinary dispatch owner | Separate initial-owner boundary | Remains U-04; this adapter does not repair that path |

## Shared application setup

The application keeps the live graph and its Store together while any Agent or route responsibility remains unresolved. A completed application's history-removal policy is separate from its success result.

For example, the following case session contains one Source, one Target, their edge and a job cancellation token. The in-memory Store is an executable example configuration, not a persistence recommendation. The close function deliberately forgets completed history before unloading the graph; the caller invokes it only after the saved chain is complete and history is no longer needed.

<pre id="handoff-case-shared_setup"><code># frozen_string_literal: true

require &quot;phronomy&quot;

class HandoffCaseLookup &lt; Phronomy::Tool::Base
  tool_name &quot;handoff_case_lookup&quot;
  description &quot;Read the facts for one case&quot;
  execution_mode :cooperative
  param :case_id, type: :string, desc: &quot;Case identity&quot;

  def execute(case_id:)
    &quot;Facts for #{case_id}&quot;
  end
end

class HandoffCaseSource &lt; Phronomy::Agent::Base
  agent_definition id: &quot;handoff-case-source&quot;, version: 1
  model &quot;gpt-4o-mini&quot;
  provider :openai
  tools HandoffCaseLookup =&gt; nil
end

class HandoffCaseTarget &lt; Phronomy::Agent::Base
  agent_definition id: &quot;handoff-case-target&quot;, version: 1
  model &quot;gpt-4o-mini&quot;
  provider :openai
end

def open_handoff_case
  stores = Phronomy::PersistenceComposition.in_memory
  source = HandoffCaseSource.create(persistence: stores.agent)
  target = HandoffCaseTarget.create(persistence: stores.agent)
  edge = Phronomy::MultiAgent::Handoff.new(source_agent: source, target_agent: target)
  runner = Phronomy::MultiAgent::HandoffRunner.new(main_agent: source,
    persistence: stores.multi_agent, handoffs: [edge])
  {stores: stores, source: source, target: target, edge: edge, runner: runner,
   agents: [source, target].to_h { |agent| [agent.agent_id, agent] },
   config: {cancellation_token: Phronomy::Concurrency::CancellationToken.new}}
end

# The caller chooses when completed history may be forgotten. Never call this
# while a save, Agent execution or Handoff target remains unresolved.
def close_completed_handoff_case(session)
  session.fetch(:runner).forget_history!
  session.fetch(:source).unload!
  session.fetch(:target).unload!
end
</code></pre>

The example model name and provider are configured application inputs. Acceptance replaces the Provider HTTP response with the existing offline LLM test adapter; no live Provider result is claimed.

## Complete normal application before and after

Normal turn entry remains the application's existing Runner invocation. No recovery bookkeeping is required when the save and its observation succeed.

For example, the same session and `"case-42"` input below produce `"case-42 completed"` in the offline acceptance fixture. These complete functions are byte-identical and are executed against the exact applied baseline and candidate.

<table><thead><tr><th>Applied baseline</th><th>U-03 candidate</th></tr></thead><tbody><tr><td><pre id="handoff-case-normal_before"><code># frozen_string_literal: true

def run_handoff_case(session, input)
  session.fetch(:runner).invoke(input, config: session.fetch(:config))
end
</code></pre></td><td><pre id="handoff-case-normal_after"><code># frozen_string_literal: true

def run_handoff_case(session, input)
  session.fetch(:runner).invoke(input, config: session.fetch(:config))
end
</code></pre></td></tr></tbody></table>

## Complete recovery application before and after

Recovery adds a separate observation and an explicit policy choice for the same captured save. A resolved Agent receipt permits waiting for that Agent's continuation; completing the Handoff chain still requires the Runner's exact-turn operation.

For example, the default policy below keeps a confirmed pre-state pending. Setting `retry_confirmed_pre: true` authorizes one captured-write retry. The helper then waits for the retained Agent execution and resumes its exact chain. It never calls `invoke` to recover an already started turn.

The baseline wrapper is an adaptation using only existing public APIs; it has no recovery mechanism. The candidate's recovery behavior is an intentional fix, not an equivalence claim under the injected fault. The complete normal path above remains the equivalence comparison.

<table><thead><tr><th>Applied baseline</th><th>U-03 candidate</th></tr></thead><tbody><tr><td><pre id="handoff-case-recovery_before"><code># frozen_string_literal: true

# Baseline application: the original call owns the only observation here.
# No retained Handoff dispatch recovery or exact-chain resume is available.
def start_handoff_case(session, input)
  {state: :completed, result: run_handoff_case(session, input)}
end
</code></pre></td><td><pre id="handoff-case-recovery_after"><code># frozen_string_literal: true

def start_handoff_case(session, input, retry_confirmed_pre: false, wait_timeout: nil)
  {state: :completed, result: run_handoff_case(session, input)}
rescue Phronomy::Agent::DispatchRecoveryError =&gt; failure
  recover_handoff_case(session, failure.recovery,
    retry_confirmed_pre: retry_confirmed_pre, wait_timeout: wait_timeout)
end

# Reconciliation reads. Only this explicit application policy authorizes one
# captured-write retry after the saved pre-state has been confirmed.
def recover_handoff_case(session, recovery, retry_confirmed_pre: false, wait_timeout: nil)
  agent = session.fetch(:agents).fetch(recovery.agent_id)
  receipt = agent.reconcile_dispatch(recovery: recovery)
  if receipt.outcome == :confirmed_pre &amp;&amp; retry_confirmed_pre
    receipt = agent.retry_dispatch(recovery: recovery)
  end
  pending = {state: :recovery_pending, recovery: recovery, receipt: receipt}
  return pending unless receipt.resolved?
  finish_handoff_case(session, pending, wait_timeout: wait_timeout)
end

# A waiter timeout leaves the receipt and execution observation available.
# This timeout bounds only this Task wait, not synchronous Runner operations.
def finish_handoff_case(session, pending, wait_timeout: nil)
  receipt = pending.fetch(:receipt)
  begin
    receipt.execution_task.wait_result(timeout: wait_timeout)
  rescue Phronomy::TimeoutError =&gt; error
    # A saved Task failure is not a waiter-local timeout.
    raise if receipt.execution_task.done?
    return pending.merge(state: :execution_observation_pending, error: error)
  end
  result = session.fetch(:runner).resume(pending.fetch(:recovery).execution_id,
    config: session.fetch(:config))
  {state: :completed, result: result}
end
</code></pre></td></tr></tbody></table>

The caller retains `session` and any returned `recovery` and `receipt`. A `recovery_pending` value preserves unavailable, conflicting or confirmed-pre evidence without dispatching. An `execution_observation_pending` value preserves the receipt after a waiter-local timeout; call `finish_handoff_case` again with that value to continue observing it. `wait_timeout` bounds only the execution Task wait, not synchronous reconciliation or Runner calls. A concurrent completion may cause the timeout to propagate instead of returning a pending value; it never converts a saved task failure into success.

The helpers handle one retained obligation at a time. If continued business work produces another `DispatchRecoveryError`, the new error and capability propagate to the caller for another explicit policy decision. Other admission, authority, saved execution and observation errors also propagate. The helper does not hide them, change the original failed observation, create a retry loop or unload unresolved work.

## Public continuation and ownership contract

The Runner's exact-turn operation observes historical completion independently of current routing, and checks current routing before granting new work. Agent save recovery and Handoff continuation remain separately observable responsibilities.

For example, yesterday's case can be resumed to read its saved Target result after today's case begins on the same Agent. An unfinished historical case cannot borrow today's active Agent identity to start or resume today's work.

| Operation or condition | Defined behavior |
| --- | --- |
| `invoke(input, config: {})` | Existing normal turn entry; no implicit dispatch retry is added |
| `resume(execution_id, config: {})` | Synchronous continuation of one exact retained chain; positional ID matches Agent/Team resume and Runner cancel/result |
| Returned value from `resume` | Durable leaf fields `execution_id`, `agent_id`, `status`, `result`, `output`, `raw_output`, `error`, plus the graph's `agent` object |
| Live `invoke` value | Existing shape is preserved; transient invocation-only fields are not reconstructed by `resume` |
| Saved failed or cancelled leaf | Existing Runner `value!` error semantics apply; saved failure does not become successful output |
| Missing or unrelated identity | Existing not-found, configuration or state-conflict errors; no alternate turn is chosen |
| Pending dispatch capability on `resume` | `ExecutionRehydrationRequiredError` identifies Agent, execution and recovery, with `pending_dispatch_recovery` guidance; it does not wait on the unresolved ordinary Agent path |
| Original uncertain `invoke` | Existing typed `Agent::DispatchRecoveryError` supplies the retained capability directly |
| Absent Target | Requires exact pending Source/Target receipt, configured edge, Target definition and context, retained ownership and cancellation authority before the existing reserved admission |
| Active leaf | Requires its exact execution reservation and the current route; matching Agent ID alone is insufficient |
| Historical terminal leaf | Saved outcome without new business work. An exact current pending failed/cancelled/blocked Target now performs [separate parent finalization](handoff-initial-terminal-application.md) before delivering its failure; unrelated older terminal history remains read-only. `result` never finalizes routing. |
| Handoff count | Existing `MAX_HANDOFFS` bounds newly driven handoffs in one continuation segment; historical chain traversal is read-only and cycle checked |
| Runtime and live graph | Existing Runtime ownership and Agent lifetime restrictions remain; no stopped-owner takeover is supplied |

Agent `resume` returns an exact execution observation, including saved failures as values. Handoff Runner already applies `value!` to its business result, so the Runner continuation preserves that domain policy. This is an existing responsibility difference, not a reason to add another generic facade. A keyword-only execution ID, implicit retry-on-`invoke`, a second Handoff recovery capability and a separate asynchronous Runner protocol were considered and not adopted.

## Save proof, authority and cancellation

Captured persistence proof establishes what the original save did. Current Handoff authority establishes whether its still-unused continuation is permitted now. Both are required, and a historical post-state never replaces a fresh authority check.

For example, a cached post-state can survive a failed continuation notification. If routing changes or a required Source hold disappears before re-observation, the save remains historically confirmed but no new Provider call is authorized.

The MultiAgent evidence adapter captures immutable routing and retained-reference facts, requires unchanged participant pre/post footprints for ordinary dispatch, and replays no routing operation. The Agent layer compares the complete Agent footprint and repeats only its captured save from a confirmed pre-state. No participant callback, Policy, transformation, encoding, Provider, Tool or Source transfer is replayed to discover a save result.

Handoff routing guards precede ordered Agent guards, consistently with existing admission and cancellation. The supported live-owner protocol requires authority stability between the guarded storage check and later EventLoop continuation admission. The finite model includes a missing-stability-premise counterexample; this implementation does not claim that a released transaction lock fences arbitrary out-of-band changes.

Runner selection checks the complete chain and routing facts before choosing a Target. Later, `ReservedChildAdmission` rechecks its actual subset: the active Agent, cancellation and, only when routing is not stable, the exact pending Target identity. It does not repeat the complete selection proof or make that selection a future admission fence. Authority stability is also required across this selection-to-admission interval. The finite model bounds its reserved-Target state to non-stable routing; it does not enumerate routing phase drift across that interval or prove an unconditional pending-identity check in every phase.

Cancelling a recovery observation ends that observation only; another observer can still receive the same physical read's result. The Runner's `config[:cancellation_token]` and `cancel(execution_id)` concern the job itself. They are not observer-only cancellation switches. A logical timeout or lost notification is not evidence that a physical worker ended, a save rolled back, or an external call did not happen.

## Acceptance evidence and limits

Acceptance joins the existing Agent save protocol to actual Handoff progression and verifies the observable business calls and exact identities. The model checks the selected abstract obligations; executable Runtime cases check the implementation path.

For example, the application matrix injects rollback or committed-response loss after a Source Tool effect, makes the immediate readback unavailable, then recovers the save and follows either direct completion or transfer. Both paths keep the lookup effect at one. A separate Target case confirms that a transferred Target's next save recovers without a second Target admission.

The new real-Runtime application spec covers Provider/Tool barriers, pre/post recovery, direct/transfer outcomes, unavailable reads, cached routing and hold changes, job cancellation, independent observer cancellation during a slow read, refused continuation delivery, pending exact-resume refusal, and transferred Target authority. Original failures remain closed; post-state confirmation is separate from continuation availability. The exact assembled examples are exercised independently of this spec, including the default hold policy and waiter timeout.

The bounded model is documented in [Handoff dispatch recovery](../../spec/models/handoff_dispatch_recovery/README.md). It represents the retained Agent owner, exact-chain Runner and recovery observers separately. Existing generic dispatch/custody models remain separate evidence; this is not a full product or a Ruby refinement proof. The full delivery report records exact counts, source hashes and fresh versus reused evidence.

U-04 initial preparation, U-05 incomplete proposal preparation, U-06 arbitrary synchronous participant conformance, stopped Runtime administration, live LLM behavior and production backend matrices remain separately scoped. No capability is inferred from these offline cases for an unsupported participant or lost process-local owner.
