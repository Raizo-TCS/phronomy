# Runtime and concurrency

Phronomy uses an **EventLoop / FSMSession first** architecture for framework
lifecycle coordination. `FSMSession` represents explicit lifecycle state and
events. `Phronomy::Task` is the common caller-facing completion handle, not an
execution backend. Synchronous work that must stay off EventLoop is isolated in
the bounded `OffloadPool`.

For the design rationale, see [ADR-010](decisions/010-cooperative-first-concurrency.md).
Durable-state ownership is defined by
[ADR-014](decisions/014-unified-persistence-durable-state.md).

## Runtime model

```text
Runtime
├─ EventLoop (one control-plane operating-system Thread)
│  └─ FSMSession
│     ├─ Agent
│     ├─ Workflow
│     ├─ ToolInvocation
│     └─ MultiAgent fan-out
├─ process-local Agent ActivationRegistry
├─ OffloadPool (bounded operating-system Threads)
│  ├─ private Operation records
│  ├─ blocking input/output (I/O)
│  ├─ central-processing-unit (CPU)-bound synchronous work
│  └─ other long synchronous work
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

For Agents, the live owner consists of the Agent instance plus its current
`AgentRoot`, hydrated Journal view, and `AgentExecutionActivation`. Mutable
Agent/Execution/Journal state is not automatically reloaded before every LLM or
Tool step. Durable writes use optimistic revision/position guardrails; an
external writer that advances the durable base causes `Persistence::ConflictError`
rather than automatic reload or merge.

For Workflows, the current `WorkflowContext` and FSMSession own the active
logical state. A durable Workflow hydrates once at invocation/resume and saves at
the halted/terminal boundary.

Content-addressed `Persistence#contents` values are immutable. Fetching a known
content reference is value materialization rather than mutable state refresh.

## Workflow identities and durable admission

Workflow execution keeps three identities separate:

```text
session_id
  application session/correlation identity

thread_id
  durable Workflow identity and Persistence#workflow_states key

fsm_session_id
  one Runtime FSMSession execution identity; generated again for each invoke/resume
```

The application `session_id` is tracing/caller metadata and is not used for
durable Workflow ownership. EventLoop registers active FSMs by `fsm_session_id`;
durable Workflow admission is a separate owner map:

```text
thread_id -> owner_fsm_session_id
```

The owner is acquired before `workflow_states.load(thread_id)` and remains held
until the halted/terminal `workflow_states.save(...)` completes. The admission map
is process-local. Cross-process duplicate execution requires application-level
distributed coordination; optimistic revisions detect stale terminal commits but
do not prevent duplicate side effects before that conflict is detected.

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
`OffloadPool`; completion continues through Task callbacks or explicit EventLoop
events.

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
thread that registers after settlement. Callbacks must be thread-safe and should
complete quickly.

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

`Phronomy.reset_runtime!` exists primarily for test isolation and performs a real
Runtime shutdown before resetting configuration.

## Further design records

The `docs/decisions/` directory contains the historical and current Architecture
Decision Records. When an older ADR is superseded, use the superseding
section/current ADR as the active design contract and keep earlier documents as
historical rationale.
