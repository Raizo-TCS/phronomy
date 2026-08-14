# Runtime and concurrency

Phronomy uses an **EventLoop / FSMSession first** architecture for framework
lifecycle coordination. `FSMSession` is the framework finite-state-machine session
used to represent explicit lifecycle state and events. A `Task` is a completion
handle, not an execution backend. Synchronous work that must stay off EventLoop is isolated in the bounded
`OffloadPool`.

For the design rationale, see Architecture Decision Record (ADR)
[ADR-010: EventLoop / FSMSession First Concurrency](decisions/010-cooperative-first-concurrency.md).
Durable-state ownership is defined by
[ADR-014: Unified Persistence and Durable-State Ownership](decisions/014-unified-persistence-durable-state.md).

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
│  ├─ blocking input/output (I/O)
│  ├─ central-processing-unit (CPU)-bound synchronous work
│  └─ other long synchronous work
├─ named OffloadPools
└─ EventLoop-driven timers

Task = completion handle
```

The framework does not allocate one operating-system Thread per logical Agent/Workflow/Tool
lifecycle. Logical waits remain explicit states plus later EventLoop events.

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
logical state. A durable Workflow hydrates once at invocation/resume and saves
at the halted/terminal boundary.

Content-addressed `Persistence#contents` values are immutable. Fetching a known
content reference is value materialization rather than mutable state refresh.

## Workflow identities and durable admission

Workflow execution keeps three identities separate:

```text
session_id
  application session/correlation identity, for example a Rails session

thread_id
  durable Workflow identity and Persistence#workflow_states key

fsm_session_id
  one Runtime FSMSession execution identity; generated again for each
  invoke/resume operation
```

The existing application `session_id` is tracing/caller metadata and is not used
for durable Workflow ownership. EventLoop registers active FSMs by
`fsm_session_id`; durable Workflow admission is a separate owner map:

```text
thread_id -> owner_fsm_session_id
```

The owner is acquired before `workflow_states.load(thread_id)` and remains held
until the halted/terminal `workflow_states.save(...)` completes. Only the current
owner may release the admission. `fsm_session_id` is Runtime-only metadata and is
not stored in Workflow fields or durable snapshots.

## Tool execution modes

Phronomy exposes two execution modes for capabilities:

- `:cooperative` — short EventLoop-safe work, or a specialized asynchronous Tool
  that starts another Phronomy lifecycle and returns immediately.
- `:offloaded` — synchronous work that must not run to completion on EventLoop.

Phronomy does not classify application work into framework-level I/O/CPU/process
execution modes. That workload classification and capacity planning belong to the
application.

A CPU-heavy operation may therefore use `:offloaded`, but thread offload does not
remove CRuby Global VM Lock contention or physical CPU contention.

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
  → child settles
  → post parent EventLoop event
```

This distinction prevents worker-slot starvation when many logical lifecycles are
waiting at the same time.

## Persistence I/O boundary

`Persistence` repositories expose synchronous operations. Framework lifecycle
code must not perform potentially blocking durable reads/writes on EventLoop.
Agent preparation/commit and Workflow hydrate/save operations are submitted to
`OffloadPool`; completion continues through completion callbacks or explicit
EventLoop events.

A durable barrier may pause one logical lifecycle without blocking EventLoop.
The next Agent provider call does not start until the corresponding Manifest and
logical execution snapshot commit succeeds. A persistence failure or optimistic
conflict fails that step rather than continuing with stale state.

Approval wait is not a hydration boundary. The same live Agent instance,
Activation, and AgentInvocation remain the owner and are resumed after approval.
Class-level approval convenience routing resolves that live Activation through
the Runtime registry rather than loading another Agent.

## Sync versus async application APIs

| Calling context | Recommended approach |
|---|---|
| Top-level application code | `agent.invoke(...)` when blocking the caller is acceptable |
| Top-level explicit async | `task = agent.invoke_async(...)`; optionally `task.wait_result` outside EventLoop |
| Workflow entry/transition action | Start async work and continue through `Workflow#signal` |
| EventLoop callback | Never block waiting for a Task that requires EventLoop progress |
| Top-level streaming | `agent.stream(...)` |
| Non-blocking streaming | `agent.stream_async(...)` |
| Approval from EventLoop callback | `approve_async` |

Blocking synchronous APIs reject EventLoop re-entry with
`Phronomy::EventLoopReentrancyError` when waiting would stall the same EventLoop
needed for progress.

## Task

`Phronomy::Task` is thread-free. It represents one terminal result:

- completed value,
- failure,
- cancellation.

`Task#wait_result(timeout:)` is a bridge for external synchronous callers. It is
not the framework continuation mechanism.

`Task#map` is application-level composition. A transformation exception settles
the mapped Task as failed. This is different from independent notification
callbacks, described below.

## OffloadPool

`OffloadPool` is a bounded worker pool for synchronous work that must not execute
on EventLoop.

Its guarantees include:

- bounded worker count,
- bounded queue depth,
- queue backpressure,
- operation-wide submit timeout/cancellation settlement,
- abandoned-worker accounting,
- runtime metrics,
- shutdown/drain behavior.

It does not guarantee CPU/I/O fairness or CPU isolation. Applications that need
resource isolation can create named Runtime pools.

### EventLoop queue admission

Framework-owned EventLoop-origin submissions must not wait for a free worker
queue slot. They use non-blocking admission (`on_full: :raise`) and route
`BackpressureError` through the ordinary FSM/completion path.

External management threads may choose a blocking admission policy when blocking
the caller is acceptable.

## PendingOperation and blocking_wait

`OffloadPool#submit` returns a private `PendingOperation` immediately after queue
admission.

`PendingOperation#blocking_wait(timeout:)` is intentionally a **low-level
synchronous bridge** for non-EventLoop callers such as tests and diagnostics.
The timeout belongs only to that waiter:

- it raises `TimeoutError` to that calling thread,
- it does not settle the PendingOperation,
- it does not cancel the submitted operation,
- it does not mark the operation abandoned.

There is no waiter-local `cancellation_token:` argument. Operation-wide
cancellation belongs exclusively to `OffloadPool#submit(cancellation_token:)`.

## Submit timeout and cancellation

Submit-time timeout and submit cancellation settle the caller-facing operation.
They do **not** asynchronously interrupt an already-running synchronous worker.

### Before worker start

If timeout/cancellation wins before execution starts:

- the PendingOperation settles,
- the submitted block does not run,
- the operation is not counted as abandoned.

### After worker start

If timeout/cancellation wins after execution starts:

- the PendingOperation settles immediately,
- the operation is marked abandoned,
- the worker is allowed to continue until its synchronous call returns,
- the eventual worker result is discarded.

Phronomy does not use `Thread#raise` to inject an exception into the worker.
Application/library code that needs hard or transport-level deadlines should use
its native timeout or, in the future, an appropriate process-isolation mechanism.

### CancellationToken deadlines

`CancellationToken.timeout_after(seconds)` uses a monotonic deadline.
`cancelled?` becomes true after that deadline, but the token itself does not own a
Thread.

Components requiring callback delivery for a monotonic deadline must promote the
deadline to explicit `cancel!` through the Runtime timer queue. OffloadPool does
this for its submit cancellation token.

`CancellationScope#deadline_in` is appropriate when the application needs a
Runtime-timer-backed cancellation scope whose `on_cancel` subscribers are fired
on expiry.

## Independent notification callbacks

Independent notification fan-out is fault-isolated.

The rule applies to:

- `CancellationToken#on_cancel`,
- `Task#on_complete`,
- `PendingOperation#on_complete`,
- EventLoop timer callbacks.

A `StandardError` from one independent subscriber is logged and does not suppress
later subscribers.

This is deliberately different from a continuation/transform such as
`Task#map`: a transform exception is the outcome of the derived operation and is
therefore propagated into that derived Task.

Callback execution thread is not guaranteed for low-level completion handles.
Callbacks must therefore be thread-safe and should complete quickly. Framework
lifecycle code normally turns completion into an explicit EventLoop event rather
than mutating unrelated logical state from a worker thread.

## Abandoned-worker metrics

Two metrics answer different operational questions:

- `offload_pool_abandoned_total` — cumulative count of operations that became
  abandoned after worker execution had started.
- `offload_pool_abandoned_active` — current number of abandoned operations whose
  synchronous workers still occupy pool capacity.

Example:

```text
offload_pool_size             = 10
offload_pool_active           = 10
offload_pool_abandoned_active = 8
offload_pool_abandoned_total  = 523
offload_pool_queue_length     = 40
```

This means 10 workers are currently executing, 8 of them are doing work whose
caller-facing result has already been abandoned, 523 abandonment events have
occurred since process start, and 40 operations are queued.

`Phronomy::Diagnostics.dump` exposes the same distinction for point-in-time
troubleshooting.

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
Decision Records (ADRs). When an older ADR is superseded, use the superseding
section/current ADR as the active design contract and keep the earlier document
as historical rationale.
