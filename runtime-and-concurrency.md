# Runtime and concurrency

Phronomy uses an **EventLoop / FSMSession first** architecture for framework
lifecycle coordination. `FSMSession` represents explicit lifecycle state and
events. `Phronomy::Task` is the common caller-facing completion handle, not an
execution backend. Synchronous work that must stay off EventLoop is isolated in
the bounded `OffloadPool`.

For the design rationale, see [ADR-010](decisions/010-cooperative-first-concurrency.md).
Durable-state ownership is defined by
[ADR-014](decisions/014-unified-persistence-durable-state.md), with live Agent
Runtime execution-state ownership refined by
[ADR-024](decisions/024-event-loop-single-writer-agent-runtime.md) and process-local
Agent identity/admission ownership defined by
[ADR-025](decisions/025-process-local-agent-ownership-and-runtime-admission.md).
Canonical Workflow instance identity is defined by
[ADR-020](decisions/020-canonical-workflow-instance-identity.md).
Concrete FSMSession incarnation identity and session-local Runtime routing are
defined by [ADR-023](decisions/023-fsm-session-incarnation-identity-and-routing.md).
Same-process Workflow admission ownership and durable terminal-barrier ordering
are defined by
[ADR-026](decisions/026-workflow-runtime-admission-and-durable-terminal-barrier.md).

## Runtime model

```text
Runtime
├─ Agent ownership registry
│  └─ agent_id -> one mutable live Agent instance
├─ EventLoop (one control-plane operating-system Thread)
│  ├─ FSMSession
│  │  ├─ Agent
│  │  ├─ Workflow
│  │  ├─ ToolInvocation
│  │  └─ MultiAgent fan-out
│  ├─ Agent top-level admission
│  │  └─ agent_id -> one nonterminal logical Execution admission
│  └─ Agent execution directory
│     └─ execution_id -> immutable live-state record
├─ OffloadPool (bounded operating-system Threads)
│  ├─ private Operation records
│  ├─ blocking input/output (I/O)
│  ├─ central-processing-unit (CPU)-bound synchronous work
│  └─ operation-specific durable Agent/Workflow work
├─ named OffloadPools
└─ EventLoop-driven timers

EventLoop / FSMSession ─┐
                       ├─> Task = completion handle
OffloadPool ────────────┘
```

The framework does not allocate one operating-system Thread per logical
Agent/Workflow/Tool lifecycle. Logical waits remain explicit states plus later
EventLoop events.

## Live state and durable state

A live Agent or Workflow owns its current logical state. `Persistence` is the
last committed durable representation and recovery source; it is not reloaded at
every semantic boundary.

For active Agents, **EventLoop is the single writer of Phronomy-managed live
execution state**. EventLoop owns a process-local execution directory keyed by
canonical `execution_id`. Each directory value is immutable and is replaced on
EventLoop when the current AgentExecution, RuntimeProjection, AgentInvocation, or
owning FSMSession changes. The former mutex-protected
`AgentExecutionActivation` / `ActivationRegistry` model is removed.

`AgentInvocation` is the FSM-local mutable context and holds uncommitted Provider
outcomes, Tool/runtime events, active Provider-call provenance, and callback
failure state. These fields are advanced only by EventLoop-driven FSMSession
handling; workers do not receive AgentInvocation as a mutable state authority.

Mutable Agent/Execution/Journal state is not automatically reloaded before every
LLM or Tool step. Durable writes use optimistic revision/position guardrails; an
external writer that advances the durable base causes
`Persistence::ConflictError` rather than automatic reload or merge.

For Workflows, the current `WorkflowContext` and FSMSession own the active
logical state. A durable Workflow hydrates once at invocation/resume and saves at
the halted/terminal boundary.

Content-addressed `Persistence#contents` values are immutable. Fetching a known
content reference is value materialization rather than mutable state refresh.

## Process-local Agent identity ownership and admission

`agent_id` identifies one logical Agent, not a reusable lookup key for independent
mutable objects. One Runtime therefore publishes at most one mutable live Agent
instance for a given `agent_id`. The Runtime-owned registry is an authority, not a
cache, and reserves the identity before create/load materialization.

The application-facing identity operations are distinct:

```text
new / create
  create a new Agent; existing live or durable identity is an error

load(agent_id, persistence:)
  live -> exact same Ruby object, with no Persistence reload
  durable-only -> hydrate and publish once
  missing -> Persistence::NotFoundError

get(agent_id)
  live Runtime lookup only; missing -> nil
```

A live Agent is strongly owned for the Runtime lifetime even while idle and
across sequential Executions. Execution completion does not evict it. Clean
Runtime shutdown detaches old Agent objects so they cannot remain mutable beside
a later Runtime owner. `purge!` is the explicit earlier destruction boundary: it
invalidates the old object, deletes durable state, releases the process-local
identity, and allows a later new Agent to reuse the textual ID.

Live Agent ownership and top-level Execution admission are separate lifetimes.
For one live Agent, EventLoop admits at most one nonterminal top-level Execution.
Admission is acquired **before** the initial Offload/Persistence operation:

```text
invoke
  -> EventLoop Agent admission
  -> Offload/Persistence executions.create_active
  -> EventLoop live execution state
```

`preparing`, `active`, and `suspended` all retain the slot. A competing request is
rejected with `AgentBusyError`; core does not promise automatic queueing. A
known-successful durable terminal transition releases the slot. A known
pre-durable failure may release it; an uncertain durable outcome remains
fail-closed/recovery-required.

`Persistence#executions.create_active`, optimistic revision, Journal position, and
watermark checks remain required durable defenses. They do not become the
primary same-process live ownership/admission mechanism and do not provide
cross-process exclusion.

## EventLoop single-writer and Offload result application

Persistence repositories are synchronous, so durable work must remain off the
EventLoop thread. The ownership rule is therefore not "run everything on
EventLoop". It is:

```text
EventLoop
  capture operation-specific immutable state
      ↓
OffloadPool
  blocking I/O / CPU / operation-local calculation
  durable commit
      ↓ operation-specific result
EventLoop
  validate current authority
  apply committed result to live state
```

Agent initial preparation, follow-up Manifest preparation, approval resume, and
terminal commit use distinct command/result values. An Offload worker may commit
Persistence but does not update the live Agent root, Journal view, current
AgentExecution, RuntimeProjection, AgentInvocation runtime queues, or EventLoop
execution directory.

Completion callbacks are lightweight bridges that enqueue the result back to the
EventLoop. If EventLoop no longer accepts the result, the callback does not fall
back to direct live mutation.

## Provider Call result authority

Provider Call identity is purpose-specific semantic provenance. EventLoop
allocates `llm_call_id` before transport begins and binds it to the Manifest used
for that call.

Provider completion and streaming chunks return through the owning FSMSession's
EventSink and carry the `llm_call_id`. A result is applicable only when:

- it still targets the current FSMSession incarnation;
- the FSM is in the state that accepts that result; and
- the AgentInvocation still owns the same active `llm_call_id`.

A callback to an old FSMSession incarnation is dropped by session-local routing.
A result with a stale `llm_call_id` is consumed without advancing the current
FSM. Phronomy does not add a generic generation/correlation token as another
result authority.

Tool operations follow the same ownership direction. `tool_invocation_id` is the
semantic Tool-operation identity, while FSMSession ID is Runtime routing identity.
Tool authorization captures Agent identity and Tool description data as values on
EventLoop before offload. The authorization worker receives no live Agent, Tool, or
ToolInvocation reference. Application-owned approval/facts/requirement callables
are explicitly classified behavior handles and receive a value-only
`ApprovalEvaluationRequest`.

Hash, Array, and String authorization command data is recursively copied/frozen.
Phronomy-managed live domain objects are rejected from that value data. A complete
value-type/serialization contract for arbitrary Application-owned opaque objects is
deferred; such objects remain Application-owned and must be worker-safe.

Worker authorization/execution outcomes return as values carrying
`tool_invocation_id`; the Tool FSMSession consumes a mismatched semantic result
without advancing its current state.

## Approval suspension and live owner lookup

Approval suspension retains the same process-local Agent and AgentInvocation but
has no active owning FSMSession until resume. EventLoop retains the suspended
execution entry.

`Agent::Base.live_for_execution(execution_id)` resolves a read-only Runtime owner
view and returns the existing Agent instance. `agent.approve_async(...)` routes to
the same live coordinator. Neither operation reloads a replacement Agent or
Execution from Persistence.

A resume performs its durable approval transition through OffloadPool, applies
the result on EventLoop, and then builds a **fresh** FSMSession incarnation.
If the process-local owner no longer exists, durable continuation reconstruction
is not implied; `ExecutionRehydrationRequiredError` is raised.

## Workflow identities, admission, and durable terminal barrier

Workflow runtime keeps identity and coordination responsibilities separate:

```text
session_id
  application session/correlation metadata

workflow_instance_id
  logical/durable Workflow identity and Persistence#workflow_states key

admission owner token
  opaque process-local Runtime coordination capability

fsm_session_id
  one concrete Runtime FSMSession routing identity
```

EventLoop acquires the `workflow_instance_id` admission with a fresh opaque owner
token **before** `workflow_states.load(workflow_instance_id)` is submitted. The
token is not a domain identity and is never an Event target. After durable
hydration, EventLoop constructs the concrete FSMSession and binds its fresh
`fsm_session_id` to the existing admission for `Workflow#signal` routing.

```text
admit workflow_instance_id with owner token
    ↓
Offload workflow_states.load
    ↓
EventLoop hydrate / create FSMSession
    ↓
bind fsm_session_id for routing
```

A durable Workflow also keeps terminal persistence inside the FSMSession
lifecycle. Logical halt/completion first enters a private
`persisting_terminal` lifecycle condition; the FSMSession remains nonterminal
while WorkflowRunner saves the terminal snapshot through OffloadPool. Only a
known-successful save result returned to that same FSMSession permits
`HALTED`/`COMPLETED`, admission release, and caller Task settlement.

```text
RUNNING
    ↓ logical halt/completion
PERSISTING_TERMINAL
    ├─ known success  -> HALTED / COMPLETED -> release
    ├─ known failure  -> ERROR -> release
    └─ outcome unknown -> RECOVERY_REQUIRED (fail closed)
```

The FSMSession does not know whether Persistence is local, remote, SQL, HTTP, or
networked. The Workflow persistence operation normalizes the result into
`success`, `known_failure`, or `outcome_unknown`. Only known success crosses the
durable barrier. If the backend/storage error does not establish non-commit,
Phronomy treats the terminal outcome as uncertain rather than guessing.

`recovery_required` prevents a fresh same-Workflow execution segment from being
admitted, but ACS-13 does not claim restart-safe reconciliation; that remains
ACS-15 work. The admission map itself is process-local. Cross-process duplicate
execution requires the later coordination/fencing work; optimistic revisions
remain durable conflict defense rather than distributed ownership.

## Tool execution modes

Phronomy exposes two execution modes for capabilities:

- `:cooperative` — short EventLoop-safe work, or specialized asynchronous work
  that starts another Phronomy lifecycle and returns a Task immediately;
- `:offloaded` — synchronous work that must not run to completion on EventLoop.

Both paths return `Phronomy::Task`. The execution mechanism differs; the
completion abstraction does not.

Phronomy does not classify application work into framework-level I/O/CPU/process
execution modes. Workload classification and capacity planning belong to the
application.

## Logical waiting versus offload

Do not offload a logical wait merely to make it asynchronous.

Prohibited shape:

```text
OffloadPool worker
  → child_agent.invoke_async
  → wait_result
```

Correct shape:

```text
parent FSMSession
  → start child lifecycle
  → return immediately
  → child Task settles
  → post parent EventLoop event
```

This distinction prevents worker-slot starvation when many logical lifecycles are
waiting at the same time.

## Persistence I/O boundary

`Persistence` repositories expose synchronous operations. Framework lifecycle
code must not perform potentially blocking durable reads/writes on EventLoop.
Agent preparation/commit and Workflow hydrate/save operations are submitted to
`OffloadPool`; completion continues through explicit EventLoop events.

A durable barrier may pause one logical lifecycle without blocking EventLoop.
Persistence does not implement async repository variants and must not depend on
EventLoop, FSMSession, Task settlement internals, or private OffloadPool operation
records.

## Sync versus async application APIs

| Calling context | Recommended approach |
|---|---|
| Top-level application code | `agent.invoke(...)` when blocking the caller is acceptable |
| Top-level explicit async | `task = agent.invoke_async(...)`; optionally `task.wait_result` outside EventLoop |
| Workflow entry/transition action | Start async work and continue through `Workflow#signal` |
| EventLoop callback | Never block waiting for a Task that requires EventLoop progress |
| Top-level streaming | `agent.stream(...)` |
| Non-blocking streaming | `agent.stream_async(...)` |
| Approval from EventLoop callback | Resolve with `live_for_execution`, call `agent.approve_async(...)`, and return immediately |

Blocking synchronous APIs reject EventLoop re-entry with
`Phronomy::EventLoopReentrancyError` when waiting would stall the same EventLoop
needed for progress.

## Task

`Phronomy::Task` is thread-free. It represents one terminal result:

- completed value;
- failure;
- cancellation.

Task is the common completion abstraction for logical EventLoop/FSMSession
lifecycles and OffloadPool-backed synchronous work.

`Task#wait_result(timeout:)` is a bridge for external synchronous callers. Its
timeout is waiter-local: it does not settle/cancel the Task or alter OffloadPool
abandonment state.

`Task#on_complete` registers an independent notification callback. Callback
execution thread is not guaranteed. A callback may be delivered by an OffloadPool
worker, a timer/cancellation caller, an EventLoop-related control path, or the
thread that registers after settlement. Callbacks must therefore be thread-safe
and should complete quickly. Framework lifecycle code normally converts worker
completion into an explicit EventLoop event before applying live state.

`Task#map` is application-level composition. A transformation exception settles
the mapped Task as failed.

Framework components own Task settlement. Application code should not use
`Task#complete`, `Task#fail`, or `Task#cancel!` as operation-control APIs. Request
operation-wide cancellation through the `CancellationToken` accepted by the API
that created the Task. Task settlement never propagates backwards to cancel a
shared CancellationToken.

## OffloadPool

`OffloadPool` is a bounded worker pool for synchronous work that must not execute
on EventLoop.

Its guarantees include:

- bounded worker count;
- bounded queue depth;
- queue backpressure;
- operation-wide submit timeout/cancellation settlement;
- abandoned-worker accounting;
- runtime metrics;
- shutdown/drain behavior.

`OffloadPool#submit` returns a `Phronomy::Task`. OffloadPool does not expose its
execution record as a caller-facing future/promise. Its private `Operation` owns:

- the submitted block;
- queue submission/start timing;
- worker-start linearization;
- submit timeout/cancellation flags;
- abandoned state;
- cancellation callback lifecycle;
- metrics state needed by the pool.

This separation keeps execution details private while allowing every asynchronous
Phronomy API to expose the same Task completion contract.

### EventLoop queue admission

Framework-owned EventLoop-origin submissions must not wait for a free worker
queue slot. They use non-blocking admission (`on_full: :raise`) and route
`BackpressureError` through the ordinary FSM/Task completion path.

External management threads may choose a blocking admission policy when blocking
the caller is acceptable.

## Submit timeout and cancellation

Submit-time timeout and submit cancellation settle the caller-facing Task. They
do **not** asynchronously interrupt an already-running synchronous worker.

### Before worker start

If timeout/cancellation wins before execution starts:

- the Task settles (`TimeoutError` failure or cancellation);
- the submitted block does not run;
- the private Operation is not counted as abandoned.

### After worker start

If timeout/cancellation wins after execution starts:

- the Task settles immediately;
- the private Operation is marked abandoned;
- the worker continues until its synchronous call returns;
- the eventual worker result is discarded.

Phronomy does not use `Thread#raise` to inject an exception into the worker.
Application/library code that needs hard or transport-level deadlines should use
its native timeout or an appropriate future process-isolation mechanism.

### CancellationToken deadlines

`CancellationToken.timeout_after(seconds)` uses a monotonic deadline. Components
requiring callback delivery promote the deadline to explicit `cancel!` through
the Runtime timer queue. OffloadPool does this for its submit cancellation token.

A CancellationToken may be shared by multiple operations. For that reason,
settling or cancelling one Task does not cancel the token in the reverse
direction.

## Native async boundary

A genuine native-async driver that does not create a Phronomy-owned OS Thread and
does not block EventLoop need not consume an OffloadPool worker. If Phronomy
formally exposes such an extension point, it must adapt completion to
`Phronomy::Task` rather than exposing a provider-specific future or a private
Runtime type.

The current Persistence, VectorStore, Embeddings, and LLM call-extension
contracts are synchronous at the external implementation boundary where
applicable. Phronomy owns the OffloadPool wrapper for synchronous work. The
current VectorStore async methods are framework convenience methods, not a
native-async backend SPI.

## Abandoned-worker metrics

Two metrics answer different operational questions:

- `offload_pool_abandoned_total` — cumulative count of operations that became
  abandoned after worker execution had started;
- `offload_pool_abandoned_active` — current number of abandoned operations whose
  synchronous workers still occupy pool capacity.

The abandonment state belongs to the private OffloadPool Operation, not to Task.
Task reports only caller-facing settlement.

## EventLoop metrics

`Phronomy::Metrics.snapshot` also reports EventLoop queue depth and lag values.
Use these to distinguish worker saturation from EventLoop backlog/latency.

## Shutdown

`Runtime#shutdown` is terminal for that Runtime. It drains/terminates the
Runtime-owned EventLoop, then closes pools and timers according to the Runtime
shutdown contract.

Workflow durable admission participates in EventLoop idleness: a Workflow whose
FSMSession has ended but whose durable save is still in flight remains owned until
that save completes and owner-aware admission is released.

Suspended Agent execution owner entries are process-local continuation state and
do not by themselves keep Runtime shutdown waiting. Runtime/process loss does not
imply durable Agent continuation reconstruction.

`Phronomy.reset_runtime!` exists primarily for test isolation and performs a real
Runtime shutdown before resetting configuration.

## Further design records

The `docs/decisions/` directory contains the historical and current Architecture
Decision Records. When an older ADR is superseded, use the superseding
section/current ADR as the active design contract and keep earlier documents as
historical rationale.
