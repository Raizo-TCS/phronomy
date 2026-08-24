# ADR-026: Workflow Runtime Admission and Durable Terminal Barrier

**Status**: Accepted
**Date**: 2026-08-24
**Partially supersedes**: [ADR-014](014-unified-persistence-durable-state.md) for same-process Workflow admission ownership and terminal durable-barrier ordering
**Refines**: [ADR-023](023-fsm-session-incarnation-identity-and-routing.md) by removing the transitional Workflow FSMSession-identity reservation bridge
**Complements**: [ADR-018](018-durability-guarantees-and-failure-model.md), [ADR-020](020-canonical-workflow-instance-identity.md), [ADR-024](024-event-loop-single-writer-agent-runtime.md), [ADR-025](025-process-local-agent-ownership-and-runtime-admission.md)

---

## Context

`workflow_instance_id` is the canonical logical/durable Workflow identity.
`fsm_session_id` identifies one concrete Runtime FSMSession incarnation. Those
identities have different responsibilities and lifetimes.

Before this decision, WorkflowRunner reserved the future FSMSession identity
before durable hydration and reused that value as the process-local Workflow
admission owner. This preserved admission-before-load ordering, but it conflated
Runtime coordination ownership with concrete event-routing identity.

Durable Workflow terminalization also had the wrong lifecycle order. A
FSMSession first became `halted`/`finished`, EventLoop removed the session and
settled its source completion, and only then WorkflowRunner saved the final
Workflow snapshot. A save failure could therefore occur after the runtime
lifecycle had already declared the execution segment terminal.

The Architecture Baseline requires both inconsistencies to be removed:

```text
acquire Workflow admission
    ↓
load / hydrate durable Workflow state
    ↓
create and run one concrete FSMSession
    ↓
logical halt / completion reached
    ↓
persist terminal snapshot
    ↓
known-successful persistence result returns to that FSMSession
    ↓
HALTED / COMPLETED
    ↓
release Workflow admission
    ↓
settle caller-facing Task
```

## Decision

### Workflow admission uses an opaque Runtime owner token

EventLoop owns a process-local Workflow admission entry keyed by
`workflow_instance_id`. Admission ownership uses a fresh opaque owner token that
is independent from the later concrete `fsm_session_id`:

```text
workflow_instance_id = W
        ↓
admission owner token = T1
        ↓
concrete FSMSession id = S1
```

The token is a Runtime coordination capability only. It is not a domain
identity, durable identifier, application correlation value, generic generation
counter, or asynchronous semantic-result authority.

Only the exact owner token that acquired the admission may bind or release it.
A competing/stale token cannot release the current Workflow execution segment.

### Admission precedes mutable durable hydration

Start/resume requests are first posted to EventLoop. EventLoop acquires the
`workflow_instance_id` admission before any `workflow_states.load` is submitted
to OffloadPool.

A durable load returns only operation-specific value/snapshot data. Hydration,
WorkflowContext construction, concrete FSMSession construction, admission-to-
FSMSession binding, and registration are applied on EventLoop.

This preserves the ordering:

```text
admit W with T1
    ↓
load W
    ↓
hydrate live Workflow state
    ↓
create S1
    ↓
bind T1 -> S1 for routing
```

`fsm_session_id` remains the direct EventLoop routing identity. Application
`Workflow#signal(workflow_instance_id: ...)` resolves the current admission to
its bound `fsm_session_id`; the owner token is never used as an event target.

### Durable Workflow terminalization is part of the FSMSession lifecycle

A durable Workflow that reaches logical halt/completion does not immediately
become runtime-terminal. The logical Workflow phase and the terminal-persistence
lifecycle are separate.

Conceptually:

```text
RUNNING
   ↓ logical halt/completion result
PERSISTING_TERMINAL
   ↓ terminal persistence result
   ├─ known success  -> HALTED / COMPLETED
   ├─ known failure  -> ERROR
   └─ outcome unknown -> RECOVERY_REQUIRED
```

`PERSISTING_TERMINAL` is not injected into the application-defined Workflow
state graph. It is private FSMSession/runtime lifecycle state.

When a durable terminal boundary is reached, FSMSession keeps its concrete
session alive and asks WorkflowRunner to persist the terminal snapshot.
WorkflowRunner submits a Workflow-specific immutable/value persistence command
to OffloadPool. The persistence result returns through the same FSMSession's
session-local event sink. Only that FSMSession may accept the result and advance
its terminal lifecycle.

Ephemeral Workflow executions that do not require durable terminal persistence
retain their direct terminal behavior.

### The FSM consumes semantic persistence outcomes, not backend details

FSMSession does not know whether the backend is local, remote, SQL, HTTP-based,
or otherwise networked. It does not classify database-driver or transport
exceptions.

The Workflow persistence operation normalizes the save result into three
semantic outcomes:

```text
success
  Phronomy has a known-successful durable result.

known_failure
  the Phronomy Persistence contract establishes that the intended terminal
  save did not become the successful durable transition.

outcome_unknown
  Phronomy cannot establish whether the durable transition committed.
```

For the durable-barrier question, only `success` is permission to proceed.
Both other outcomes keep the success barrier closed.

Portable Persistence semantic errors whose contract establishes ordinary
failure, such as optimistic conflict or serialization rejection, may be treated
as `known_failure`. An arbitrary backend/storage/transport error is not assumed
to mean "not committed"; when non-commit is not established by contract, the
result is conservatively `outcome_unknown`.

This classification depends on semantic certainty, not on whether the physical
backend is on the same machine or reached over a network.

### Known failure follows the Workflow error path

A `known_failure` terminal save result is delivered back to the owning
FSMSession. The FSMSession does not enter `HALTED`/`COMPLETED`; it terminalizes
through its error path instead. EventLoop then releases the admission using the
opaque owner token and the caller-facing Task settles as failed.

Phronomy does not automatically retry the entire Workflow segment merely because
the terminal durable save failed. External-effect retry/duplicate semantics are
separate architecture concerns.

### Outcome uncertainty fails closed

An `outcome_unknown` result is not converted to ordinary failure and is not
assumed to be success. The known-success durable barrier remains closed.

The concrete FSMSession loses normal continuation authority and is retired. The
process-local Workflow admission becomes `recovery_required` and remains owned,
so the Runtime cannot admit a fresh top-level segment from an unproven lineage.
The caller-facing Workflow Task is not falsely settled as success or failure.

Actual persistence-outcome reconciliation and restart-safe continuation are
ACS-15 responsibilities. ACS-13 establishes the fail-closed boundary but does
not claim that recovery is already implemented.

### Successful terminalization releases admission after FSM acceptance

On a known-successful terminal save, the result first returns to the same
FSMSession. The FSMSession accepts it and only then emits its normal
`halted`/`finished` terminal event.

EventLoop removes the concrete session, and WorkflowRunner releases the
`workflow_instance_id` admission using its opaque owner token before settling
the caller-facing Task.

The save completing on a worker thread is therefore not itself Workflow
completion. Authoritative logical completion occurs only after the EventLoop-
owned lifecycle accepts that save result.

## Required invariants

1. One Runtime admits at most one live Workflow execution segment for a `workflow_instance_id`.
2. Workflow admission is acquired before mutable durable Workflow load/hydration.
3. Workflow admission owner token and `fsm_session_id` are different Runtime concepts.
4. Only the exact admission owner token may bind/release its Workflow admission.
5. `fsm_session_id` remains the concrete EventLoop event-routing identity.
6. Durable halt/completion does not become runtime-terminal before a known-successful terminal snapshot save is accepted by the owning FSMSession.
7. Terminal Persistence I/O never blocks EventLoop and never mutates the live FSMSession from a worker.
8. FSMSession receives backend-independent semantic save outcomes, not backend/transport classifications.
9. Known terminal save failure does not become successful `HALTED`/`COMPLETED`.
10. Unknown terminal save outcome does not release admission or settle the caller Workflow Task as a terminal success/failure.
11. Ephemeral Workflows do not acquire a fake durable barrier merely to match the durable path.
12. Persistence optimistic revision remains a durable integrity/conflict defense and is not the same-process ownership mechanism.

## Explicitly deferred work

This decision does **not** implement:

- cross-process Workflow ownership, routing, lease/fencing (ACS-14);
- Persistence F1 outcome reconciliation or restart-safe Workflow rehydration (ACS-15);
- cancellation/semantic-deadline quiescence and terminalization integration (ACS-16);
- general external semantic-operation retry/idempotency protocol (ACS-17);
- a new public Workflow lifecycle-state API;
- Persistence-backend-specific network/driver exception taxonomies in FSM code.

## Rejected alternatives

### Continue using the future `fsm_session_id` as admission owner

Rejected. It preserves pre-load exclusion but conflates coordination ownership
with concrete routing identity and makes the admission authority depend on a
session that does not yet exist.

### Save only after FSMSession has emitted `halted`/`finished`

Rejected. Runtime terminalization would precede the durable outcome that is
required to justify it, violating the Workflow durable barrier.

### Block EventLoop until Persistence returns

Rejected. A durable barrier is logical execution ordering, not EventLoop-wide
blocking. Persistence remains OffloadPool work.

### Treat every save exception as known failure

Rejected. A backend may have committed even though its success response was not
observed. Blind release/retry could branch Workflow lineage or duplicate later
semantic work.

### Teach FSMSession about SQL/network/backend exception classes

Rejected. Physical backend topology and driver error taxonomies belong below the
Workflow FSM boundary. FSMSession consumes semantic persistence outcomes only.
