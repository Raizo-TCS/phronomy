# Phronomy — Unified Persistence and Runtime Ownership

## Overview

`Phronomy::Persistence` is the single durable-state backend abstraction for both
stateful Agents and durable Workflows.

```text
Persistence
├─ contents
├─ agents
├─ journals
├─ executions
└─ workflow_states
```

Runtime-only state is deliberately outside Persistence. In particular,
`AgentExecutionActivation` instances are process-local continuation state and are
owned by the Runtime activation registry.

## Agent ownership

After an Agent is created or loaded, the live Agent instance owns its current
logical state. Persistence is the durable representation of that state; it is not
reloaded before every Large Language Model (LLM) or Tool boundary.

The live state consists of:

```text
Agent instance
├─ current AgentRoot
├─ hydrated Journal view
└─ AgentExecutionActivation
   ├─ current AgentExecution
   ├─ AgentInvocation
   └─ uncommitted Runtime facts
```

A successful commit advances both the durable revision and the corresponding
local owner state. A conflicting external write raises
`Phronomy::Persistence::ConflictError`; Phronomy does not silently reload or
merge external state into a live Agent.

At next-LLM durable barriers, `Persistence#assert_agent_watermark!` checks the
Agent revision and Journal position owned by the live instance. The check returns
no replacement state; it is only a conflict precondition.

Content objects are content-addressed and immutable. Dereferencing a content
reference is therefore not a mutable-state reload.

## Approval suspension and resume

Approval suspension does not transfer ownership. The same Agent instance,
Activation, and AgentInvocation remain live while approval is pending.

Instance-level `agent.approve_async(...)` resumes that live Activation.
Class-level approval convenience APIs resolve the same Activation through the
Runtime registry and route the request to `activation.agent`; they do not load a
new Agent from Persistence.

If no live Activation exists, durable continuation reconstruction is not yet
implemented and `ExecutionRehydrationRequiredError` is raised.

## Workflow persistence repository

`Persistence#workflow_states` stores snapshots by durable `thread_id`.
Repository records have this conceptual shape:

```ruby
{
  snapshot: {
    fields: workflow_context.to_h,
    phase: workflow_context.phase.to_s
  },
  revision: 3
}
```

Writes and deletes use optimistic compare-and-swap semantics with
`expected_revision:`. A missing row has no revision; the first successful save
creates revision `1`.

Workflow field values are application data. `Persistence::InMemory` therefore
uses a recursive Ruby deep-copy strategy for Workflow snapshots rather than
requiring them to be Marshal-compatible.

## Workflow identity

Three identities are distinct:

```text
session_id
  application session/correlation identity, for example a Rails session

thread_id
  durable Workflow identity and workflow_states repository key

fsm_session_id
  one Runtime FSMSession execution identity, freshly generated for each
  invoke/resume operation
```

`fsm_session_id` is Runtime metadata. It is not stored in Workflow fields or in
the durable Workflow snapshot.

The EventLoop session registry is keyed by `fsm_session_id`. Durable Workflow
admission is separate:

```text
thread_id -> owner_fsm_session_id
```

The owner acquires admission before loading durable state and retains it through
the terminal/halted save:

```text
admit(thread_id, owner_fsm_session_id)
→ Persistence#workflow_states.load(thread_id)
→ FSMSession execution
→ Persistence#workflow_states.save(...)
→ release(thread_id, owner_fsm_session_id)
→ settle public Task
```

Only the current owner may release the admission. This prevents an unsuccessful
competing invocation from releasing another invocation's reservation, and closes
the stale-load window while the previous owner is still saving.

## EventLoop and Persistence

Persistence remains a synchronous repository abstraction. Operations that may
block must not run on the Runtime EventLoop thread. Framework-owned Workflow
loads/saves and Agent durable preparation/commit operations are submitted to the
bounded OffloadPool, and their completions return to the EventLoop through
explicit events or completion handles.

Logical waiting is represented by FSM state plus a later EventLoop event. No
OffloadPool worker is consumed merely to wait for another Phronomy lifecycle.

## In-memory transaction boundary

`Persistence::InMemory` has one shared `Monitor` protecting all durable
repositories. Agent state and Workflow state therefore participate in the same
in-process atomic transaction boundary.

Workflow snapshot storage is kept in a separate data container from the
Marshal-snapshotted Agent repositories so non-Marshalable Workflow application
values do not break Agent transactions. Both containers are still protected and
rolled back by the same Monitor-owned transaction.

## What is not durable

The following are not persisted as Workflow or Agent durable state:

- FSMSession objects and `fsm_session_id` values;
- Runtime activation registry entries;
- `Task` instances and callbacks;
- EventLoop queue contents;
- in-flight provider operations.

Process-loss recovery of an in-flight Agent Activation requires an explicit
future rehydration design rather than serializing Runtime objects.
