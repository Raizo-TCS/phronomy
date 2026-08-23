# ADR 014: Unified Persistence for Durable State

**Status**: Accepted
**Date**: 2026-08-14
**Supersedes**: ADR-009
**Partially superseded by**:
- [ADR-020](020-canonical-workflow-instance-identity.md) for Workflow identity terminology only
- [ADR-021](021-generic-agent-invocation-identity-removal.md) for `InvocationContext` generic session/correlation semantics and Agent-side generic invocation identity

---

## Context

Phronomy historically had two durable-state abstractions:

- `Phronomy::Persistence` for Agent roots, Journals, content and executions;
- `Phronomy::StateStore` for Workflow snapshots.

At the same time, `Persistence` exposed `activations`, although
`AgentExecutionActivation` contains live process state such as the active
AgentInvocation, FSMSession, runtime projection, callbacks and uncommitted runtime
facts. That state is not a durable database record.

Keeping two durable backend abstractions makes SQL/database backends implement the
same responsibility twice. Treating live Activations as Persistence also mixes
process-local execution ownership with durable storage ownership.

A second problem is state freshness. Re-reading mutable Agent records from
Persistence before every semantic boundary makes the durable copy act as the
source of truth even while a live Agent instance is executing. That makes
ownership ambiguous and encourages implicit merge/reload semantics.

Workflow runtime identity also needs to be distinct from its durable identity.
`InvocationContext#session_id` already means application session metadata (for
example a Rails session), while Workflow `thread_id` identifies durable Workflow
state. Neither value is the identity of one concrete FSMSession execution.

## Decision

### Persistence is the only durable backend abstraction

`Phronomy::Persistence` exposes the durable repositories:

```text
contents
agents
journals
executions
workflow_states
```

`Phronomy::StateStore` is removed without a compatibility adapter. Workflow
persistence is configured with `persistence:` or
`Phronomy.configuration.persistence` and stored through
`Persistence#workflow_states`. Agent `new`/`create` also uses the global
Persistence when no explicit backend is injected, so an application can select
one durable backend for both domains. Explicit injection takes precedence.

The `workflow_states` repository uses optimistic revision metadata:

```ruby
record = persistence.workflow_states.load(thread_id)
# => nil or { snapshot: ..., revision: Integer }

persistence.workflow_states.save(
  thread_id,
  expected_revision: record&.fetch(:revision),
  snapshot: snapshot
)
```

A stale expected revision raises `Phronomy::Persistence::ConflictError`. Upper
layers do not automatically reload and merge after such a conflict.

The normative contract for custom durable backends, including repository
semantics, transaction requirements, capabilities, durable codecs, and the Agent
watermark precondition, is documented in
[`docs/persistence-backends.md`](../persistence-backends.md).

### Activation is transient Runtime state

`AgentExecutionActivation` is not part of the Persistence contract. Live
Activations are held by a Runtime-local `Agent::ActivationRegistry`.

Durable execution rehydration is a separate future capability. When no live
Activation exists, approval resume raises
`ExecutionRehydrationRequiredError`; the framework does not silently construct a
new Agent and pretend that the process-local execution was recovered.

### A live Agent instance owns its logical current state

After hydration, the live Agent instance and its Activation are authoritative for
mutable logical state:

```text
Agent instance
├─ current AgentRoot
├─ hydrated Journal/context view
└─ active execution entry

AgentExecutionActivation
├─ current AgentExecution
├─ runtime projection
├─ Provider results
├─ Tool/runtime events
└─ active AgentInvocation / call state
```

Persistence is the last committed durable representation and recovery source.
Normal LLM/Tool cycles do not re-read mutable AgentRoot, AgentExecution or Journal
records merely to obtain freshness. Successful optimistic commits advance the
local root/execution/Journals; failed revision checks surface a conflict.

Before a next-LLM durable barrier, the backend verifies the live owner's Agent
revision and Journal position as a durable watermark. This check is a precondition
only: it does not return replacement state to the live Agent. If another writer
has advanced either value, the barrier raises `ConflictError` and no Provider
Call starts from the stale local owner.

Content-addressed `contents` are immutable values and may still be dereferenced by
content reference on demand. That is not a mutable-state refresh.

Context Policy therefore sees the current local logical state rather than a
Persistence readback. Runtime facts captured after a Persistence snapshot remain
in the Activation and are eligible at the next semantic boundary.

### Approval resumes the same owner

An approval suspension retains the original Agent instance,
`AgentExecutionActivation` and `AgentInvocation`. Instance-level
`agent.approve` / `agent.approve_async` resume that live Activation.

When an application has only an `execution_id`, it resolves the current process's
live owner first:

```text
execution_id
  -> Agent::Base.live_for_execution(...)
  -> Runtime ActivationRegistry
  -> live Activation
  -> activation.agent
```

A concrete Agent class may call `MyAgent.live_for_execution(execution_id)` to
also verify that the live owner is an instance of that class. The lookup does not
load Agent or Execution state from Persistence. If the live Activation no longer
exists, `ExecutionRehydrationRequiredError` is raised rather than silently
rehydrating another owner.

Approval remains an Agent-instance operation after lookup:

```ruby
agent = MyAgent.live_for_execution(execution_id)
agent.approve_async(execution_id, approval_request_id: request_id)
```

### Workflow has three distinct identities

The following identities must not be conflated:

```text
application session_id
    caller/tracing identity, e.g. Rails session

thread_id
    durable Workflow identity / workflow_states key

fsm_session_id
    Runtime-only identity of one FSMSession invocation or resume
```

Each Workflow invocation/resume receives a fresh `fsm_session_id`. The EventLoop
registers the session by that ID.

For a Workflow with a durable `thread_id`, EventLoop also owns a separate
admission table:

```text
thread_id -> owner_fsm_session_id
```

Admission is acquired before Persistence load and held through FSM execution and
terminal snapshot save. Release succeeds only when the supplied
`owner_fsm_session_id` is the current owner. A failed competing invocation can
therefore never release another invocation's reservation.

The admission table belongs to one Runtime and is process-local. It prevents
competing execution of the same `thread_id` inside that Runtime, but it is not a
distributed lease and is not shared by multiple Ruby processes, containers, or
service replicas. Two processes may therefore execute the same durable
`thread_id` concurrently if an application routes work that way.

`workflow_states` optimistic revisions still detect stale/double commits between
those processes. They do not prevent both executions from starting and cannot
roll back external side effects already performed before one terminal save loses
the revision race. CAS is therefore stale/double-commit protection, not
distributed execution exclusion or duplicate-side-effect prevention.

`fsm_session_id` is Runtime metadata. It is not an application Workflow field and
is not stored in `workflow_states` snapshots.

### Persistence I/O stays off EventLoop

The Persistence repository contract remains synchronous. Persistence operations
started by EventLoop-driven Workflow/Agent lifecycle code execute through the
bounded OffloadPool. Completion is converted back into an EventLoop event where
lifecycle ordering requires it.

No worker waits synchronously for an FSMSession or Task that requires EventLoop
progress.

### Backend synchronization is an implementation detail

`Persistence::InMemory` uses one shared `Monitor` for all durable repositories,
including `workflow_states`. Workflow values retain StateStore-like deep-copy
semantics and are kept outside the Marshal snapshot used by the existing Agent
state container, while both remain inside the same transaction domain.

A SQL backend should implement the same repository/transaction contract using DB
transactions, isolation and optimistic revision constraints. Mutex/Monitor and
Ruby object identity are not part of the public repository contract.

## Consequences

### Positive

- Agent and Workflow durability share one backend configuration and transaction
  abstraction.
- Process-local Activation state is no longer presented as durable Persistence.
- Active Agent ownership is explicit; Context Policy freshness no longer depends
  on repeated mutable-state reloads.
- Approval owner lookup and approval execution are separate: class-level lookup
  resolves the existing live Agent, while approval remains an instance operation.
- Revision conflicts are visible instead of being hidden by automatic merge.
- Workflow durable identity is independent of one Runtime FSMSession execution.
- Owner-aware Workflow admission closes the stale-load window during terminal
  save inside one Runtime.
- InMemory and future SQL backends can share one contract test suite.

### Trade-offs

- Removing `StateStore` is a pre-1.0 breaking change.
- A process restart cannot resume an approval until durable Activation/FSM
  rehydration is implemented separately.
- Runtime Activation lookup and Workflow admission are process-local. Applications
  requiring cross-process ownership or duplicate-execution prevention need a
  separate routing/lease/fencing design.
- Optimistic Workflow revisions can reject a stale commit but cannot undo
  duplicate external side effects performed before that conflict is observed.
- Applications that intentionally allow another process to edit the same live
  Agent or Workflow must handle `ConflictError` and explicitly reload/reconcile.
- `Persistence` implementations must provide `workflow_states` and optimistic
  revision semantics.

## Rejected alternatives

### Keep StateStore as a compatibility facade

Rejected. It preserves the duplicate durable-backend abstraction and makes future
backend behavior harder to reason about.

### Reload Agent state before every LLM call

Rejected. It makes Persistence the live source of truth, creates implicit merge
semantics and conflicts with Agent-instance ownership.

### Use Workflow thread_id as FSMSession id

Rejected. Durable identity and one Runtime execution have different lifetimes.
It also makes owner-aware admission and application `session_id` terminology
ambiguous.

### Release Workflow admission by thread_id only

Rejected. Cleanup from an invocation that failed to acquire admission could then
release the real owner's reservation. Release is owner-aware by construction.
