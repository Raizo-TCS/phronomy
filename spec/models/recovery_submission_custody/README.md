# Recovery submission custody model

This bounded TLA+ model checks the physical responsibility retained by an
original Workflow or Agent owner when an executor does not return a task handle.
It separates actual executor admission, evidence available to the owner, worker
mailbox values, physical completion and caller observation. It covers the initial
Workflow terminal save and the later reconciliation or captured-write retry
attempts that must remain behind that save's physical barrier.

For example, a Workflow finishes its research steps and submits its final save.
A fault-injecting adapter enqueues that save, then raises before returning its
handle. The original caller may receive a recovery error, but the original owner
must retain the queued save. A later mailbox value does not permit a replacement
Workflow or a concurrent reconciliation read: the missing executor completion
channel still prevents a physical-completion proof.

## Evidence and responsibility

The submission mechanism supplies positive refusal evidence, while the retained
domain owner decides whether it can relinquish a particular physical slot. A
truthful refusal before enqueue permits that slot to close. A returned handle
consumes the execution right even when its worker remains queued. Worker entry
also proves acceptance, but does not recover a missing completion handle.

For example, a reconciliation read can fail to return its handle after its
worker starts. The owner knows that work was accepted and still cannot prove
that work is physically quiet. Closing the caller's observation must leave the
read's slot retained so another explicit call cannot start an overlapping read
or captured-write retry.

| Observed evidence | Slot consequence |
| --- | --- |
| Positive refusal for this attempt, no handle and no worker entry | The attempt is physically absent; its slot may close. |
| Returned handle, worker still queued | The accepted slot remains tracked until physical completion. |
| Exception without a handle or positive refusal | The slot remains unresolved even when the worker has not started. |
| Worker entry or mailbox value without a returned handle | Acceptance or a result is known; physical completion is still unknown. |
| Returned handle and authoritative physical completion | The owner may classify the domain result and finish that slot. |
| Caller cancellation, observation failure or Runtime stop | The observation may close; accepted responsibility remains retained. |

The model assumes a truthful refusal callback. A callback that claims refusal
and then enqueues the same attempt violates the executor contract. The built-in
OffloadPool does not need a lost-handle fault to reject a full or closed queue;
those supported rejections provide positive evidence. The enqueue-then-throw
cases deliberately stress a faulting adapter and must not be described as the
normal behavior of that pool.

## Bounded initial and attempt states

The model keeps one initial save slot and at most two later explicit recovery
attempts. Executor state progresses separately through queued, running, mailbox
recorded and physically quiet states. Owner state retains its active slot,
initial-save physical barrier, confirmed application fact and admission custody.
Caller closure is independent of all of these states.

For example, the `initial` boundary begins with the first Workflow save being
submitted. If that save finishes physically but leaves its durable outcome
uncertain, a fresh explicit caller may start the first reconciliation attempt.
If that read is positively refused, another fresh caller may submit the second
attempt. If its handle is lost instead, the second attempt is forbidden.

The `attempt` boundary starts with an already physically settled initial save
and an uncertain durable outcome. It isolates the common admission obligation of
Workflow reconciliation, Agent reconciliation and Agent captured-write retry.
The read or write operation's domain body is abstracted; the model does not
identify reads with writes, authorize a mode change, or add a retry API.

| Property | Obligation |
| --- | --- |
| `NonAdmissionNeedsProof` | A rejection claim requires the same attempt's positive refusal and no accepted worker. |
| `CompletionNeedsEvidence` | Physical completion requires either proven refusal or a returned handle reporting a quiet task. |
| `UnknownSlotRetained` | A lost-handle slot remains owned until its physical completion can be proved. |
| `InitialBarrier` | A recovery attempt cannot start before the initial save is physically settled. |
| `PhysicalSerialization` | At most one modeled save, read or captured-write retry remains physically live. |
| `ReleaseSafe` | Release requires confirmed application and physical proof for every submitted slot. |
| `ClosedCallerStaysClosed` | Later recovery never reopens an already closed modeled caller. |
| `CustodyUntilRelease` | Unreleased work remains the original owner's responsibility. |

The initial worker's uncertain result and a later authoritative post-state are
abstract inputs from the adjacent persistence models. A positively refused
initial Workflow save represents its existing known-failure cleanup. A refused
recovery attempt only closes that attempt, permitting a later explicit request.
This distinction prevents initial cleanup policy from silently becoming Agent
or Workflow recovery policy.

Only Workflow's initial positive-refusal cleanup is represented here. Agent's
initial save and explicit first-submission retry remain the responsibility of
`agent_terminal_submission`; this model does not give Agent the Workflow release
policy. Ordinary initial-save success is also outside this focused abstraction:
the modeled accepted initial worker deliberately leaves an uncertain result so
the physical barrier and subsequent explicit reconciliation can be exercised.

## Progress premises and counterexamples

Progress requires the original live matching owner, truthful submission evidence,
an available returned-handle completion channel, successful domain evidence and
application, a fresh explicit caller when needed, and weak fairness of enabled
executor and owner transitions. The model checks safety with faults enabled; it
does not promise eventual resolution after losing the only completion handle.

For example, all hidden worker code can finish and the actual executor can become
quiet while the owner still lacks proof of completion. The unknown-quiet witness
reaches exactly that state with custody retained. Weak fairness cannot invent a
handle or evidence that the protocol never receives, so its missing-handle
liveness configuration intentionally reports a counterexample.

| Cases | Expected result |
| --- | --- |
| Two safety configurations, starting at the initial save or a later attempt | All adopted protocol invariants hold. |
| Initial save followed by an explicit read; refused attempt followed by an accepted attempt | Eventual release under the stated progress premises. |
| No handle treated as refusal | `NonAdmissionNeedsProof` violation. |
| A late mailbox value treated as physical completion | `CompletionNeedsEvidence` violation. |
| Unknown recovery attempt forgotten | `PhysicalSerialization` violation after another attempt is accepted. |
| Five reachability witnesses | Reach unknown-but-actually-quiet initial and attempt slots, refusal followed by acceptance, release after caller closure, and returned-but-queued work. |
| Fresh caller omitted; completion handle lost | Intended liveness violations exposing missing progress premises. |

Mutation and witness configurations negate specific properties deliberately.
Their expected counterexamples are evidence that the check can detect the
removed safeguard or reach the named state. They are not unresolved violations
in the adopted `Bug = "none"` safety configurations. State counts from separate
configurations overlap and must not be added as unique modeled states.

## Implementation correspondence and limits

The model constrains submission and physical custody at existing owner boundaries.
Domain proof, exact owner identity, state application and release policy remain
with Workflow and Agent. The shared Execution helper only forwards optional
positive rejection evidence to compatible submitters.

For example, both a Workflow read and an Agent captured-write retry need the same
physical serialization rule, but only their own persistence evidence decides
what a confirmed pre-state or post-state means. Reusing that submission rule
does not transfer the domain decision to Execution or justify a generic recovery
manager.

| Model element | Implementation responsibility |
| --- | --- |
| `Refuse` / `Throw` | `Execution.submit_with_rejection_evidence` supplies optional per-attempt refusal; the owner checks receipt, handle and worker entry. |
| Initial slot `1` | `WorkflowTerminalOperation#start` retains an uncertain initial save instead of normal failure finalization. |
| Attempt slots `2` and `3` | Workflow and Agent `observe_on_owner` retain or close the specific reconciliation/retry attempt. |
| `Enter` / `Record` | Worker entry and `capture_worker` publish facts without asserting executor quiescence. |
| `ReturnHandle` / `ObservePhysical` | `watch` and `refresh_slot` preserve the returned task and observe physical completion. |
| `FreshObservation` / `Finish` | Explicit observation joins or inspects an existing slot; it does not forget unresolved accepted work. |
| `Apply` / `Release` | Existing exact-owner application and release guards remain domain-owned. |
| `CloseCaller` / `Stop` | Closing observers or stopping a Runtime does not erase the physical obligation. |

The source baseline is G3b-3 commit
`685dae5a411a57f07179a708228906e9fb6e7d4e`. The adjacent
`agent_terminal_persistence`, `agent_terminal_recovery`,
`agent_terminal_submission` and Workflow terminal models cover wider domain
proof, replay, ownership and application behavior. These models are
complementary abstractions, not a mechanically proved composition or a Ruby
refinement proof. This model does not cover approval decisions, replacement
Runtimes, process loss, distributed recovery, arbitrary callback code, or database
linearizability. It assumes that the adjacent authoritative persistence proof
is valid when the abstract `post` result is supplied.

`LoseWatch` abstracts loss of the completion notification path while a returned
handle remains available for a fresh observation to poll. It does not enumerate
Ruby callback registration order, partial registration, or whether an observer
can safely join a pending task after registration fails. Deterministic Runtime
tests must verify those implementation-specific cases separately; the model's
progress property is not a proof of callback-joining liveness.

## Reproduction

The runner copies the exact model and configuration into output directories
outside the source tree. It preserves each TLC log and records source hashes,
the Java version, the JAR hash, commands, return codes, state counts and whether
each result matched the declared expectation.

For example, this command runs all 14 finite configurations with Java 21 and the
same TLA+ tools 1.7.4 JAR used for adjacent Phronomy models. The output directory
can be retained with the implementation review evidence.

```sh
python3 spec/models/recovery_submission_custody/run_checks.py \
  --jar /absolute/path/to/tla2tools-1.7.4.jar \
  --output /absolute/path/to/recovery-submission-custody-results
```

The verified JAR SHA-256 is
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
The JAR reports TLC version 2.19. Repeated `--case NAME` options select individual
configurations. `cases.json` defines expected results; `summary.json` in the
output directory records measured results. No model outputs, state databases or
Java binaries belong in the repository.
