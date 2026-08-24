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

Runtime-only state is deliberately outside Persistence. Active Agent execution
state is process-local and owned by the Runtime EventLoop. The former
`AgentExecutionActivation` / `ActivationRegistry` representation is not part of
the current architecture.

## Agent ownership

After an Agent is created or loaded, the live Agent instance owns its current
logical root and Journal view. During active execution, EventLoop is the single
writer of Phronomy-managed live execution state.

The current live shape is:

```text
Agent instance
├─ current AgentRoot
└─ hydrated Journal view

Runtime EventLoop
└─ execution_id -> immutable AgentExecutionState
   ├─ current AgentExecution
   ├─ current RuntimeProjection / base Manifest
   ├─ AgentInvocation
   └─ current owning fsm_session_id
```

`AgentInvocation` is the FSM-local context and owns the mutable uncommitted
Provider/Tool/runtime facts needed by that execution. It is advanced by EventLoop
FSM handling, not by an Offload worker.

A successful Persistence operation advances durable state first and returns an
operation-specific result. EventLoop validates that result against the current
Runtime authority and then advances the corresponding local state. A conflicting
external write raises `Phronomy::Persistence::ConflictError`; Phronomy does not
silently reload or merge external state into a live Agent.

At next-LLM durable barriers, `Persistence#assert_agent_watermark!` checks the
Agent revision and Journal position captured from the live instance. The check
returns no replacement state; it is only a conflict precondition.

Content objects are content-addressed and immutable. Dereferencing a content
reference is therefore not a mutable-state reload.

## Agent Persistence I/O and live apply

Persistence remains synchronous and potentially blocking. Agent durable work is
therefore split into explicit phases:

```text
EventLoop live snapshot
  -> OffloadPool operation-specific command
  -> Persistence transaction / materialization
  -> operation-specific immutable result
  -> EventLoop authority validation
  -> EventLoop live apply
```

Current Agent operation families include initial preparation, follow-up Manifest
preparation, approval-resume commit, and terminal commit.

Offload workers do not directly update:

- the live AgentRoot;
- the live Journal projection;
- EventLoop Agent execution entries;
- current AgentExecution / RuntimeProjection;
- AgentInvocation runtime fact queues.

Tool authorization applies the same ownership boundary. EventLoop captures Agent
identity, Tool description data, immutable container data, and explicitly
classified Application-owned authorization callables before submission. The
authorization worker receives no live Agent, Tool, or ToolInvocation reference,
and `ApprovalEvaluationRequest` is value-only.

## Provider result authority

One Provider Call receives an `llm_call_id` on EventLoop before transport begins.
Completion and streaming chunks return through the owning FSMSession EventSink
and carry the same semantic ID.

A Provider result is applicable only to the current FSMSession/FSM state and the
currently active `llm_call_id`. Old FSMSession callbacks are dropped by Runtime
routing; a stale Provider semantic ID is consumed without advancing the current
FSM.

`execution_id`, `fsm_session_id`, and `llm_call_id` therefore have separate roles:

```text
execution_id
  logical AgentExecution parent

fsm_session_id
  one Runtime FSMSession incarnation / routing target

llm_call_id
  one Provider Call semantic provenance identity
```

No generic session/generation/correlation ID is introduced to replace these
purpose-specific identities.

## Approval suspension and resume

Approval suspension does not transfer process-local Agent ownership. The same
Agent instance and AgentInvocation remain live, while the suspended EventLoop
execution entry temporarily has no owning FSMSession.

Instance-level `agent.approve(...)` / `agent.approve_async(...)` resume that live
owner. If an application has only an `execution_id`, it first resolves the
process-local owner with:

```ruby
agent = Phronomy::Agent::Base.live_for_execution(execution_id)
```

or, when the expected Agent class is known:

```ruby
agent = MyAgent.live_for_execution(execution_id)
```

The lookup resolves `execution_id -> Runtime/EventLoop owner view -> Agent`. It
does not expose AgentInvocation/current execution mutable internals and does not
load a new Agent or Execution from Persistence.

If no live owner exists, durable continuation reconstruction is not yet
implemented and `ExecutionRehydrationRequiredError` is raised.

`execution_id` is a routing identity, not an authorization token. Applications
must separately authorize the caller to act on the resolved Agent / approval
request.

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

This admission map belongs to one Runtime and is process-local. Separate Ruby
processes, containers, or service replicas can each admit the same durable
`thread_id`. Optimistic Workflow revisions detect stale terminal commits between
those processes, but they do not prevent duplicate execution from starting and
cannot undo external side effects already performed before a revision conflict is
observed.

Opaque Workflow admission ownership remains ACS-13 work and is intentionally not
redefined by ACS-11.

## EventLoop and Persistence

Persistence remains a synchronous repository abstraction. Operations that may
block must not run on the Runtime EventLoop thread. Framework-owned Workflow
loads/saves and Agent durable operations are submitted to bounded OffloadPool
workers.

For Agent execution, worker completion returns to EventLoop before Phronomy live
state is advanced. For Workflow, lifecycle ordering continues through its
existing explicit persistence-result EventLoop path.

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
- EventLoop Agent execution-directory entries;
- AgentInvocation objects and active Provider-operation state;
- Runtime Workflow admission entries;
- `Task` instances and callbacks;
- EventLoop queue contents;
- in-flight provider operations.

Process-loss recovery of an in-flight Agent execution requires the separate
ACS-15 rehydration design rather than serializing Runtime objects. Cross-process
exclusive Workflow execution likewise requires a separate distributed
lease/fencing design; optimistic revisions alone are commit-conflict detection,
not distributed execution locking.
