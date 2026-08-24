# ADR-025: Process-Local Agent Ownership and Runtime Admission

**Status**: Accepted
**Date**: 2026-08-24
**Partially supersedes**: [ADR-014](014-unified-persistence-durable-state.md) for same-process Agent live-instance ownership and top-level execution admission
**Complements**: [ADR-018](018-durability-guarantees-and-failure-model.md), [ADR-022](022-agent-execution-parent-identity-and-runtime-routing-boundary.md), [ADR-023](023-fsm-session-incarnation-identity-and-routing.md), [ADR-024](024-event-loop-single-writer-agent-runtime.md)

---

## Context

Phronomy's durable Agent identity is `agent_id`. The architecture baseline treats
that value as the identity of one logical Agent, not as a database lookup key
that may be reused by several independent mutable Ruby objects.

Before this decision, `Agent::Base.load(agent_id, persistence:)` could hydrate a
new mutable Agent every time it was called. The same process could therefore
hold two independent live objects that both represented the same logical Agent.
Separately, top-level `invoke` requests reached EventLoop, but the first concrete
same-Agent exclusion was still `Persistence#executions.create_active` inside the
initial Offload/Persistence operation.

That placement confused three different authorities:

```text
Runtime
  process-local live Agent ownership

EventLoop
  process-local top-level execution admission and live execution progression

Persistence
  last confirmed durable representation, atomic durable transition,
  optimistic conflict detection and recovery source
```

ADR-024 made EventLoop the single writer of Phronomy-managed live Agent
execution state. ACS-12 adds the process-local logical-Agent ownership and
admission layer on top of that foundation without turning Persistence into a
live ownership service.

## Decision

### One `agent_id` has one mutable live Agent owner per Runtime

A Runtime owns a purpose-specific Agent ownership registry keyed only by
`agent_id`:

```text
agent_id
  -> one mutable live Agent instance
```

The registry is an ownership authority, not a cache. Immutable snapshots,
durable records, read-only projections and handles may still have multiple
representations of the same Agent identity.

Agent ownership is reserved before durable create/load and before the mutable
Agent is published. Concurrent materialization of the same identity therefore
cannot create two independent live objects.

The registry is separate from EventLoop's `execution_id -> AgentExecutionState`
directory. Agent lifetime and Execution lifetime are different semantic
lifetimes and must not be represented by one registry.

### Public Agent construction/resolution semantics

The public operations have distinct meanings:

```text
new / create
  create a new logical Agent
  existing live or durable identity -> AgentAlreadyExistsError

load(agent_id, persistence:)
  resolve an existing logical Agent
  live owner -> return the exact same Ruby object without Persistence reload
  durable-only -> hydrate once and publish as the live owner
  missing durable Agent -> Persistence::NotFoundError

get(agent_id)
  process-local live-owner lookup only
  live -> exact same Ruby object
  not live -> nil
  never loads Persistence
```

A live identity resolved through an incompatible Agent class/definition is an
explicit configuration error; it is not treated as a cache miss. A `load` call
that supplies a different Persistence instance from the already-live Agent is
also rejected rather than silently ignoring the caller's backend argument.

Ruby `.new` remains supported because it is an established application-facing
construction path. Its meaning is creation, not lookup: `.new(agent_id: "A")`
does not return an already-existing A.

### Ownership normally lasts for the Runtime lifetime

Once a mutable Agent is live, the Runtime keeps a strong ownership reference.
Execution completion, idleness and Ruby GC do not release that identity.

A clean Runtime shutdown detaches all live Agent objects from that Runtime. An
old Ruby reference is no longer a usable mutable Agent after shutdown; attempts
to operate on it fail with `RuntimeShutdownError`. This prevents a stale object
from remaining mutable while a new Runtime hydrates the same `agent_id`.

Live Agent entries do not themselves keep Runtime shutdown from completing.
Only an in-progress ownership transition such as construction or purge must
settle before clean ownership detachment.

### `purge!` is explicit logical-Agent destruction

`purge!` is the explicit exception to Runtime-lifetime ownership. It first moves
the exact current live owner into a process-local purging state, preventing new
materialization/admission, then deletes the durable Agent state.

On known successful purge:

```text
old Agent object -> permanently purged / unusable
Runtime registry  -> identity released
Persistence       -> Agent/Journal/Execution records deleted
```

The same textual `agent_id` may then be used to create a new logical Agent. A
stale Ruby reference to the old purged object remains invalid and cannot purge
or mutate the replacement. Repeating `purge!` on that already-purged stale
object is an idempotent no-op.

If the purge is known not to have committed, the process-local purging state is
rolled back to live. If durable outcome is uncertain, the transition becomes a
stable `RECOVERY_REQUIRED` ownership state. The identity stays fail-closed, but
load/shutdown waiters are not left blocked on a transition that can no longer
settle by itself. ACS-15 recovery/reconciliation work is responsible for
resolving that uncertainty.

### EventLoop owns same-process top-level execution admission

A live Agent may be idle while still owned. Top-level Execution admission is a
separate EventLoop-owned map keyed by `agent_id`.

For one logical Agent, at most one nonterminal top-level Execution is admitted:

```text
IDLE + invoke(E1)
  -> ADMITTING(E1)

ADMITTING / EXECUTING / SUSPENDED / RECOVERY_REQUIRED + invoke(E2)
  -> AgentBusyError
```

The admission is acquired on EventLoop before the initial Offload/Persistence
operation. `Persistence#executions.create_active` remains in that operation as a
durable second line of defense.

A short-lived opaque owner token protects the pre-durable `ADMITTING` entry so
only the request that acquired it may release/bind it. The token is a
process-local coordination capability only. It is not a domain identity,
semantic operation ID, generic generation counter or asynchronous result
authority. After durable establishment, the admission is bound to the canonical
`execution_id`.

### Admission follows the logical Execution lifetime

`preparing`, `active` and `suspended` are all nonterminal. Suspension keeps the
same admission; approval resume continues the same `execution_id` and does not
create a new top-level Execution.

The slot is released only after a known-successful durable terminal transition.
Caller-facing Task settlement and terminal callbacks are notification boundaries
and do not extend the logical Execution lifetime.

A known pre-durable failure releases the process-local admission. An uncertain
durable establishment/terminal outcome does not. It is marked
`RECOVERY_REQUIRED`/fail-closed so another top-level Execution cannot be admitted
from an unproven state lineage.

### Persistence admission remains a durable integrity capability

`atomic_admission` and `executions.create_active` remain required Persistence
capabilities. They continue to guarantee durable execution-ID uniqueness and
that durable nonterminal executions for one `agent_id` do not overlap.

They are no longer described as the primary same-process live/execution
ownership mechanism. Their role is durable integrity and defensive conflict
detection, including protection against stale code paths and unsupported
multi-process races.

Optimistic revision, Journal position and watermark guards remain unchanged.
Phronomy does not reload/merge durable state after a conflict to continue the
same logical execution.

## Required invariants

1. One Runtime never publishes two independent mutable Agent objects for the same `agent_id`.
2. Repeated `load` of a live Agent returns the same Ruby object and does not reload durable state.
3. `get` is process-local and never performs Persistence I/O.
4. Agent ownership and EventLoop execution-state directories remain separate responsibilities.
5. EventLoop admission occurs before initial Persistence execution establishment.
6. Competing same-Agent top-level requests are rejected with `AgentBusyError`; core does not promise automatic queueing.
7. Suspension retains the same logical Execution admission.
8. Known durable terminal success releases admission before caller notification is required to settle.
9. Unknown durable outcome never causes a blind admission release.
10. Persistence `create_active`/CAS/revision/watermark protection remains enabled as durable defense.
11. Runtime shutdown makes old live Agent objects unusable before a later Runtime can authoritatively hydrate the same identity.
12. Successful `purge!` invalidates the old object before the identity may represent a replacement live Agent.

## Explicitly deferred work

This decision does **not** implement:

- cross-process Agent ownership, lease/fencing or stable routing (ACS-14);
- durable outcome reconciliation/Agent execution rehydration (ACS-15);
- cancellation-wide physical-work quiescence supervision (ACS-16);
- semantic external-operation retry/causal barriers (ACS-17);
- a general Agent duplication contract.

The future Agent duplication operation is named **`copy`**, not `fork`. It must
create a new `agent_id`. Which Context, Knowledge, Journal history, metadata or
provenance is copied, and how nonterminal Execution state is handled, remain a
separate API/semantic decision. ACS-12 does not add `copy` to the runtime API.

## Rejected alternatives

### Use Persistence `create_active` as the only same-process exclusion

Rejected. It preserves durable exclusion behavior but leaves Runtime authority
ambiguous and allows competing requests to reach durable I/O before the
process-local owner has decided which continuation is authoritative.

### Put Agent live ownership into EventLoop's execution directory

Rejected. A live Agent exists while idle and across many sequential Executions.
`agent_id` ownership and `execution_id` Runtime state have different lifetimes.

### Let repeated `load` create a new object and rely on CAS later

Rejected. CAS detects stale durable writes after two mutable owners already
exist; it does not satisfy the logical Agent identity invariant.

### Make `.new` return an existing instance

Rejected. Ruby `.new` is creation semantics. Returning an existing object would
make identity lookup implicit and surprising; `load`/`get` provide resolution.

### Release ownership when an Execution completes or when GC collects the Agent

Rejected. Execution lifetime is shorter than logical Agent live lifetime, and GC
timing is not an architecture ownership protocol.
