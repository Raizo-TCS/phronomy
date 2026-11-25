# Physical facts in Agent recovery

Agent terminal recovery and approval recovery need the same account of a worker's
result, logical task completion and physical completion. Their owners retain the
different decisions about admission, persistence, continuation and custody.

For example, cancelling a caller's wait can finish its task observation while a
save is still writing. Both owners must retain the physical obligation. Once the
write ends, its recorded result takes precedence over the cancelled observation.
Approval may then restore its original wait or resume its retained continuation;
terminal recovery may apply its confirmed result or retain an authorized retry.

## Shared record and owner boundary

One `PhysicalAttempt` records the completion facts for one original save or
explicit recovery attempt. The owning operation selects the attempt and decides
what its facts permit; the record does not perform domain actions.

For example, a refused submission has a logical error and can have physical
completion proved without running a worker. The owner supplies that conclusion
to `submission_failed_locked`; the record never infers refusal from an exception
or missing task handle.

| Responsibility | Location |
| --- | --- |
| Task handle, logical/physical facts, worker result and callback-registration error | `PhysicalAttempt` |
| Task callbacks, snapshot fallback and worker-result precedence | `PhysicalAttempt` |
| Started/refused/unknown admission evidence and attempt identity | Recovery owner |
| Observer coalescing, original diagnostic error and original-wait acknowledgement | Recovery owner |
| Pre/post interpretation, retry authorization, live application and custody release | Recovery owner |

The two owners keep their existing slot records for identity, operation kind,
admission facts and observers. Each slot holds one completion record. A temporary
snapshot combines these views for an owner decision; it is not another mutable
authority. Workflow is outside this extraction because its comparable lifecycle
must be evaluated independently before reuse.

## Atomic decisions and callback delivery

The completion record shares its owner's existing mutex so that physical facts
and domain state can participate in one atomic decision. Task protocol calls and
owner notifications run outside that mutex, since registration may execute a
callback immediately.

For example, registering a callback on a completed task can publish physical
completion and notify the owner before registration returns. The notification may
acquire the owner mutex again without a nested lock. A subsequent snapshot read
cannot replace a recorded worker result with an earlier cancellation result.

Readers and methods ending in `_locked` require the owner mutex. `watch` and
`refresh` acquire it only to read or publish facts. Their task calls, including
`on_complete`, `on_physical_complete`, `__snapshot` and `physical_complete?`, run
outside it. The record has no additional lock and no recovery-state machine.

The shared protocol preserves these rules:

- Logical completion alone does not prove physical completion for a task with
  the physical callback protocol.
- Physical evidence remains true when a later task snapshot is less informative.
- Explicit worker recording takes precedence even when its result and error are
  both `nil`.
- Callback-registration failure retains the handle and error for later refresh;
  it does not roll back a callback that was already registered.
- A callback retains its exact completion record. A closed attempt's callback
  cannot write into a replacement attempt, and owner delivery still checks the
  original attempt identity.

When owner release or resolution permits cleanup, the owners clear retained
task, result and error references.
Both owners also clear the private registration error; terminal recovery
previously retained that unused reference after release. Public diagnostic
receipts and recovery behavior are unchanged. Clearing is not a new lifecycle
state or a guarantee that a nonstandard delayed callback cannot publish again.

## Scope and cost of the extraction

The extraction centralizes a repeated concurrency protocol. It offers a single
place to verify callback ordering and snapshot fallback; it does not make the
recovery owners thin wrappers or reduce their domain responsibilities.

For example, a fix to worker-result precedence now applies to both Agent owners
through the same implementation. Approval's confirmed-pre restoration still has
its own acceptance test, and terminal's permitted save retry remains separate.

Against `f08d26c59b77b0157e0fa7e267fb299516342c8f`, the two owners shrink from
1,105 to 1,031 physical lines. The shared record adds 86 lines, so the combined
production source grows by 12 lines. Excluding blank and comment-only lines, the
combined count falls from 982 to 973: nine lines, not a large size reduction.
The new class and explicit mutation/snapshot methods are a real interface cost.

The benefit is removing the second implementation of physical callback handling,
logical-result fallback and refresh after registration failure while preserving
one copy of each fact and one synchronization boundary. The cost includes one
record object per attempt, temporary observation snapshots, a lock precondition
and a small adapter in each owner. No performance improvement is claimed.

Existing terminal and approval acceptance tests continue to exercise their
distinct domain decisions. The record tests cover inline callbacks, logical and
physical separation, worker-result precedence, partial registration failures,
snapshot races and isolation between old and replacement attempts. Existing
public APIs, Contract directions and application source remain unchanged.
