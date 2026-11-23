# Team cancellation delivery model

This finite TLA+ model checks the retained cancellation bridge implemented by
`MultiAgent::TeamCancellationRequest` and `TeamCoordinator`. It describes a
callback latch that wakes the existing synchronous Team host, guarded storage
confirmation, retained admission after delivery error, and explicit same-run
retry. It adds no delivery worker, timer, pool or automatic backoff.

For example, a token callback can wake a host whose child remains unfinished.
The host confirms cancellation before signalling its internal token. If the
write and readback remain unknown, the host returns a delivery error while the
request remains retained. A later explicit `resume` or `cancel` can retry that
same responsibility; the model does not assume that the application supplies
such an action automatically.

The [architecture contract](../../../docs/architecture/team-cancellation-delivery.md)
describes the public behavior. This model is additional bounded design evidence,
not a verified refinement of Ruby execution, a proof of every storage adapter,
or a rerun of the earlier Chapter 2 lifecycle models.

## State and implementation correspondence

The model keeps business truth, retained responsibility, observations and local
execution separate. Its state names are analysis symbols, not additional Ruby
enums or APIs.

For example, an authoritative terminal Team record can justify signalling an
old internal token without creating a new durable cancellation intent or
changing a successful business result to cancelled.

| Model fact | Intended implementation correspondence |
| --- | --- |
| `control.reserved`, `control.open` | Request admission precedes attaching the external callback. |
| `control.pending`, `control.accepted` | A locally accepted callback is retained independently of durable intent. |
| Current/stale callback | The immutable registration object checked by `request` and `detach`; reopening uses a different object. |
| Host checkpoint, child-wait, busy segment | `run` checkpoints and `request.wait`; arbitrary callbacks and I/O are cooperative. |
| Store/readback/signal phases | The existing guarded `update` and authoritative confirmation before local token signalling. |
| `control.disposition` | Confirmed intent or authoritative terminal disposition; neither means child physical stop. |
| Host observer versus direct observer | The original Team invocation and a separate direct-cancel caller receive distinct observations. |
| Explicit retry request | A supplied same-run `resume` or direct `cancel`, not an automatic retry service. |
| Captured Runtime/current flag | New calls reject a stale Team environment. Direct cancel uses no new executor admission. |
| Cached incomplete shutdown | A later direct confirmation does not repair Runtime or rewrite its earlier shutdown report. |

The primary safety configuration includes one exact run, one host, one tracked
synchronous control call, current versus stale callback classification, and at
most one concurrent direct-confirmation/failure interference. A direct retry
after host return is also represented. The model permits storage-response loss
and inconclusive readback, but cannot infer noncommit from either.

Callback classification is an abstraction of fresh registration identity. Old
callbacks never become current again; modulo reuse of two numeric IDs is not
assumed. Runtime replacement abstracts loss of current-generation status. It is
not evidence that public `reset_default!` permits replacement while incomplete
admissions remain.

## Checked properties and progress premises

Safety requires reservation before listening, no loss of accepted intent,
retained admission while pending, sound signalling/disposition, callback fencing,
and current-generation call admission. Confirmed business results and an
already reported incomplete shutdown remain unchanged.

For example, `NoTrackedCallOverlap` counts the represented foreground call. A
concurrent direct confirmation is a separate atomic interference action; this
property does **not** claim that every actual host/direct API call physically
serializes. Store guards/CAS and implementation tests establish their concrete
concurrency behavior.

The positive progress cases deliberately start with an accepted pending request
or an already supplied explicit retry. The business job stays active and the
child never completes in the main cancellation-progress cases, so unrelated
terminal completion cannot satisfy them vacuously.

| Case family | Premise and claim |
| --- | --- |
| Active host | The host reaches the pending checkpoint, and the synchronous storage call actually returns authoritative evidence. Pending intent is discharged. |
| Child wait | A captured callback executes; its latch wakes the host independently of child completion. |
| Busy cooperative segment | The user segment actually returns. Scheduler fairness alone cannot preempt it. |
| Explicit direct/resume retry | Storage is usable and the application has supplied the retry. The retained admission does not reject its own supported retry. |
| Failed/draining current Runtime | A supplied direct cancel can confirm using synchronous storage without new executor admission. Runtime failure and cached incomplete shutdown remain unchanged. Resume requires a running Runtime. |

`WF` on the aggregate domain-call action assumes that an enabled synchronous
operation can complete; it does not derive I/O termination from CPU scheduling.
The reliable-storage profiles exclude injected storage failures. They do not
promise eventual success under endless failures. No fairness is placed on
`SupplyExplicitRetry`; the no-retry case intentionally has a temporal
counterexample even after storage is usable.

The configuration manifest separates 30 cases into eight positive property
checks, four missing-premise temporal counterexamples, ten deliberate mutation
controls, and eight reachability witnesses. An expected counterexample is not
an unfixed violation in the adopted model and is not proof that Ruby is repaired.

## Important scope limits

The finite model isolates the bridge protocol and selected races. Its claims
must not be expanded to the whole Team lifecycle or all external effects.

For example, concurrent direct confirmation is modeled after its authoritative
store/notification step completes while the host remains paused. A later host
failure cannot rearm confirmed intent. This does not represent every schedule
where the direct notification spans host unwind or finishes afterward.

- An error classified before confirmation can still reach its caller after
  confirmation. The monotonicity claim concerns retained state, not the timing
  of every exception delivery.
- The current-generation property checks admission of a call. It does not stop
  an already-started synchronous call when a default Runtime changes later.
- Retaining request admission is not proof of child physical supervision,
  transport shutdown, observer cleanup or resource release. Those remain actual
  implementation correspondence and integration-test obligations.
- `success` and `failure` are representative immutable terminal facts. The
  model does not decide business cancellation policy or model child execution.
- Local call return does not prove that an uncertain remote transaction or
  external operation stopped. Exact idempotent intent and storage atomic/CAS
  assumptions remain explicit dependencies.
- Callback synchronization, transaction internals, all simultaneous direct
  callers, cross-process claims, crash recovery, resource limits, wall-clock
  deadlines and process replacement are not proved here.

## Running the checks

Use Java and a separately obtained TLA+ tools jar. The checker is intentionally
not vendored. Keep generated logs, traces and state directories outside this
source directory.

For example, from the repository root, run the whole manifest or one named case:

```sh
python spec/models/team_cancellation_delivery/run_checks.py \
  --jar /path/to/tla2tools.jar \
  --output /tmp/team-cancellation-model-results

python spec/models/team_cancellation_delivery/run_checks.py \
  --jar /path/to/tla2tools.jar \
  --output /tmp/team-cancellation-model-one-case \
  --case witness-concurrent-confirmation
```

The recorded development checks used OpenJDK 21.0.13 and TLA+ tools 1.7.4
(TLC 2.19), jar SHA-256
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.
The runner records the actual model/config/jar hashes, Java version, command,
exit status, state counts and whether each expected outcome matched. It copies
the inputs to each external case directory before invoking TLC, so error traces
cannot be written into the repository source tree.
