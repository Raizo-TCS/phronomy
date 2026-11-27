# Workflow terminal reconciliation model

This finite TLA+ model checks the process-local Workflow terminal-reconciliation
protocol: retain the attempted save, retire its routing session, explicitly
transfer completion custody, and reconcile through the captured owner without
repeating the save or Workflow actions. Persistence fact, owner application,
physical work, transport custody and application observation are separate state.

For example, a save can commit after its logical observation has failed. A later
read can establish noncommit only with a backend settlement and read-ordering
guarantee that excludes a subsequent commit by that original write. Once the
exact post-state is confirmed, a context-construction error must preserve that
fact and its outstanding owner responsibility.

The [implementation contract](../../../docs/architecture/workflow-terminal-reconciliation.md)
describes the Ruby API and supported profile. This model is bounded protocol
evidence, not a verified refinement of Ruby, a proof about every repository
adapter, or a replacement for the real Runtime integration tests.

## State and source correspondence

The model represents one retained terminal write, two explicit recovery calls,
two distinct attempt identities, and an old versus a replacement segment owner.
Its symbolic states are analysis vocabulary, not extra public Workflow phases.

For example, `acceptedToken = "current"` means identity with the exact retirement
envelope. It does not mean that any Boolean callback result is an acknowledgement,
or that an accepted envelope proves the save committed.

| Model fact or action | Implementation correspondence |
| --- | --- |
| `obligationHeld` before the original write | `WorkflowTerminalOperation#start` installs the operation through `WorkflowExecutionRegistry#retain_terminal_operation` before submission. |
| Original write, captured reply and physical return | `WorkflowTerminalPersistence::Command` captures the immutable snapshot/revision; `WorkflowTerminalPersistence.save` performs repository I/O. `RetainedAttempts#record_worker_locked` and `AttemptCompletion` retain its result and separate physical/logical task observations. |
| `FinishOriginal` before `StartRead` | The modeled boundary assumes the original backend write has settled and cannot commit later. A local worker or TaskResult completion maps to this boundary only when the backend/adapter contract supplies that guarantee. |
| `RetireRoute`, `AcceptCustody`, `DetachWaiter` | `WorkflowExecutionRegistry#adopt_retirement`, exact `ExecutionRetirement#accepted_by?`, and Engine retirement dispatch. |
| `custodyRefused`, retained source waiter | EventLoop retains its unaccepted retirement, receiver and completion; cleanup cannot turn refusal into successful custody transfer. |
| `ReportDeliveryFailure` | `fail_original` can fail the public observation after evidence is retained while Engine still owns its separate source completion. It does not fail or detach that source. |
| Cancelled original observation and `LookupRecovery` | `pending_terminal_recovery` exposes an unresolved capability belonging to the same compiled Workflow; it performs no storage read or retry. |
| `Request`, `StartRead`, attempt identity | Owner-side `observe_on_owner`, `RetainedAttempts` reservation/join commands, independent observation tasks, and correlated `Ready` messages. |
| `pre`, `post`, `other` evidence | `WorkflowTerminalPersistence.reconcile` uses `SnapshotComparison.compare_revisioned_snapshot`: exact intended revision and snapshot; expected pre-revision; or conflict, including an equal snapshot at a later revision. `WorkflowTerminalPersistence::Result` carries the classification. |
| `proof`, `applied`, `released` | Retained confirmation, `apply_confirmation`, and owner-aware registry release after required physical boundaries. |
| Immutable observation classification | Original TaskResult cannot reopen; later recovery calls produce new immutable results. Concrete result field fidelity is tested in Ruby. |
| Reused Workflow ID and old reply | The original owner token/operation/attempt must still match; an old capability or result cannot release the new segment. |
| `stopping` versus `stopped` | Exclusive failure cleanup may retain/notify while the owner is finishing. After owner termination, this slice cannot start new owner work or select a replacement Runtime. |

`Request` represents acceptance on the serialized owner, not merely posting an
external command. An accepted concurrent caller attaches atomically to the active
attempt. Queued-but-not-yet-accepted observations and their shutdown notification
are implementation obligations covered by integration tests. Lookup and observer
cancellation do not discard the accepted domain responsibility.

The operation's tentative retirement identity is not its confirmed adoption.
`custodyAccepted` together with `~waiterHeld` corresponds to the exact Engine
source completion reaching `confirm_retirement`; only then can `@adopted`
permit reconciliation application and release.

The exact-revision proof abstracts the repository's create revision 1 and update
N + 1 contract. `other` can represent a later equal snapshot: equality of values
alone cannot identify the attempted write. The model assumes the declared host
ownership and repository atomic/CAS contract; it does not implement distributed
leases or establish arbitrary inter-process write history.

There is a separate backend settlement and read-ordering premise.
`CommitOriginal` is enabled only while `originalPhysical` is true;
`FinishOriginal` permanently disables it. `ReadStorage` observes the current
abstract storage state. Thus the model assumes that a reconciliation read is
ordered after settlement of the attempted write and does not return an older
replica view. Local `TaskResult` completion, local worker return and revision
CAS do not, by themselves, establish either property. For example, if a network
save returns an ambiguous failure, a read sees the pre-state, and the remote
database can still commit that save afterward, `confirmed_pre` is not proven
by this model. Such a backend requires independent settlement/ordering evidence;
this slice does not add that evidence or claim support for that execution.

Repository I/O and classification belong to `WorkflowTerminalPersistence`;
scheduling, evidence capture and owner release belong to
`WorkflowTerminalOperation`. The operation retains an opaque compiled-Workflow
identity, not a Runner reference or callback. Moving these unchanged I/O rules
to the helper does not add a protocol action or change the checked model.

## Safety and observation rules

Safety keeps accepted responsibility until valid application and release, even
when a caller cancels, readback fails, delivery is refused or Runtime stops.
Completing an observation is not the same transition as releasing an owner.

For example, the model permits the public original observation to fail before
Engine accepts the retirement handoff, provided the domain record already holds
its evidence. It still forbids source-waiter detachment without exact acceptance,
and forbids reconciliation/application from using that uncertainty as release
permission.

- `AcceptedResponsibilityRetained`, `RefusedCustodyRetained` and
  `OriginalErrorHasRetainedEvidence` check independent evidence/custody retention.
- `WaiterDetachedOnlyAfterAcceptance` distinguishes current from invalid-identity
  receipt acceptance. Ruby type validation remains an implementation-test
  obligation; the model does not simulate type forgery. Its identity classes do
  not reuse numeric tokens.
- `NoPrematureRelease` requires proof, owner application, accepted custody and the
  original/read physical boundaries. The replacement owner remains independent.
- `ProofSound` and `ConfirmedFactRetained` keep noncommit separate from unknown
  and prevent observer/application failure from erasing confirmed persistence.
- `OnePhysicalRead` and `CapturedRuntimeOnly` prevent cancellation-induced overlap
  and read execution through an unavailable captured Runtime.
- `OriginalObserverImmutable`, `RecoveryObservationsImmutable` and
  `SuccessfulObservationHasProof` check immutable observed classifications.
- `ReadOnlyReconciliation` constrains this specification to one original save and
  one abstract business execution. Actual Ruby callback/write counts require
  integration tests; the invariant is not an independent source-code proof.
- `NoOldReplyChangesNewOwner` and `NoFalseCleanup` also account for a represented
  new segment. Resolving the old obligation alone cannot make its Runtime clean.

The `stopping` state means the original owner is completing exclusive cleanup;
it does not grant a new host access to live state. Refused custody remains
retained when cleanup finishes. Runtime shutdown can report incomplete before
all physical work has ended, and the cached report never changes afterward.

## Progress premises and expected counterexamples

Progress checks require an actual activation and a usable execution path. The
model does not infer application retry, storage recovery or I/O return from
ordinary scheduler fairness.

For example, the positive post-state profile begins with a supplied explicit
reconciliation request and readable storage. Removing that request yields an
expected temporal counterexample even though the correct saved state exists.

| Profile | Premise and checked claim |
| --- | --- |
| Confirmed post/pre progress | An explicit request is supplied, storage is readable, the captured owner remains live, and the read/application/physical boundary can progress. The exact old owner is released and the request receives an observation. |
| Draining owner | Reconciliation continues as existing-owner work while draining; it is not a new segment admission. |
| Original error observation | An unknown result, retirement and retained custody can progress; the original public observer receives its error. |
| Stopped owner | An explicit caller gets unavailable; no resolution or new storage work is promised. |
| Missing explicit request | Storage readability alone cannot activate another attempt. |
| Missing live owner | A stopped owner cannot execute the recovery protocol. |
| Physical return followed by explicit request | The owner already retains uncertainty. The original write returns, then the host supplies its next request; this must progress to release. |
| Missing original physical return | The matching profile omits only physical-return fairness. The post-return host request remains a premise, but cannot be enabled while the write remains active. |
| Missing read physical return | Classification and delivery fairness do not prove that a still-active read physically ended. |
| Missing readable storage | A returned read failure does not become confirmed persistence merely because its task finished. |

Weak fairness on `FinishOriginal` assumes eventual backend write settlement
under the correspondence premise above; `FinishRead` assumes the read physically
returns. Neither is a claim that CPU time preempts blocked I/O. No
fairness is placed on ordinary `Request`. Most positive profiles supply the
request as an initial premise. The paired physical-return profiles instead use
`WF_s(SupplyAfterPhysical)` to assume caller reactivation after the write returns.
This host-input premise is separate from I/O return and owner scheduling; an
early call declined as unavailable is not an automatic retry reservation.
Fault-injection safety profiles permit refusal, cancellation,
application failure and finite retry, without promising unconditional progress.

`cases.json` separates positive property checks, missing-premise temporal
counterexamples, deliberate mutation controls and reachability witnesses. Each
mutation must violate its named invariant; each witness deliberately violates
the negation of a desired reachable state. These expected counterexamples are
sensitivity evidence, not unfixed violations in the adopted model.

## Bounds and unmodeled implementation obligations

The finite bounds isolate protocol decisions while keeping environmental
assumptions visible. They do not justify extrapolation to every caller count,
storage implementation or callback schedule.

For example, two distinct attempt IDs can expose cancellation overlap and a
late old reply. This does not prove an unbounded allocation algorithm, nor does
it model an arbitrary number of simultaneous callers.

- There is one original terminal save, two callers/attempt IDs, and one potential
  replacement segment. Identity is current versus distinct/stale, not modulo
  reuse of identifiers.
- A refused custody handoff remains refused in this bounded model. Retrying the
  same retained Engine envelope is an implementation behavior, not a progress
  guarantee checked by these profiles.
- The original Runtime is live/draining, finishing cleanup, or unavailable. Two
  simultaneously running Runtime generations, arbitrary forged Ruby handles and
  registry implementation details are concrete validation obligations.
- Observations store immutable classifications. Public `application_state`,
  `ownership_state`, error/cause objects, context metadata and copying must also
  match the owner facts in Ruby tests; the model does not inspect Ruby objects.
- Graph callbacks, arbitrary context constructors and physical task adapters
  are not implemented here. The model separates their effects and assumes
  accurate physical-completion declarations from the supported adapter.
  Original-write settlement and ordered readback additionally require the
  backend guarantee described above; local physical completion alone is
  insufficient.
- The model may publish read evidence before physical-end notification, while
  the implementation can impose a stronger physical/logical gate. Release must
  remain safe under either ordering.
- A failed/stopped Runtime retains responsibility and reports unavailable.
  Exclusive post-stop custody transfer, crash recovery, durable request inboxes,
  global history lookup and cross-process exactly-once effects are outside this
  implementation slice and this model.
- `CHECK_DEADLOCK FALSE` permits intentional retained terminal states. Progress
  is checked through explicit temporal properties with stated premises, not by
  interpreting every quiescent state as a defect.

## Current implementation mapping (2026-11-28)

The Workflow terminal owner uses C13 `RetainedAttempts` for the initial attempt,
one recovery lane, admission facts and observer membership, and
`AttemptCompletion` for worker results and logical/physical evidence. The owner
retains custody acceptance, persistence classification, context reconstruction and execution-segment release. The current command, snapshot and mutex boundaries are documented in
[shared retained-attempt management](../../../docs/architecture/retained-attempts.md).

For example, an observer can finish while the save worker is still running.
The shared manager keeps the physical lane and recorded worker facts; the owner
later decides what those facts authorize. Registering an inline callback or
merging a stale task snapshot is still a concrete Ruby implementation obligation.

This mapping update does not change the TLA+ transitions, configuration bounds,
expected counterexamples or progress premises. The models do not count mutex
acquisitions or enumerate partial callback registration. Fresh protocol-model
runs and their exact input hashes are recorded in delivery evidence; neither a
fresh run nor this correspondence table proves refinement of the Ruby code.

## Running and interpreting the checks

The runner invokes a separately supplied TLA+ tools jar and keeps generated
state, trace and log files outside the model source directory. It records exact
inputs and verifies the expected outcome class, not just a nonzero exit code.

For example, from the repository root, run all cases or one sensitivity control:

```sh
python3 spec/models/workflow_terminal_reconciliation/run_checks.py \
  --jar /path/to/tla2tools.jar \
  --output /tmp/workflow-terminal-model-results

python3 spec/models/workflow_terminal_reconciliation/run_checks.py \
  --jar /path/to/tla2tools.jar \
  --output /tmp/workflow-terminal-model-one-case \
  --case bug-wrong-custody-receipt
```

Development uses OpenJDK 21.0.13 and TLA+ tools 1.7.4 (TLC 2.19), jar SHA-256
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
The runner records actual Java and jar identity, model/config hashes, command,
exit status, state counts and expected-result agreement in `summary.json`.
Generated evidence and the jar are intentionally excluded from this source tree.
