# ADR-010: EventLoop / FSMSession First Concurrency

## Status

Accepted — revised for a single Task completion contract and the OffloadPool
execution boundary.

## Context

Phronomy must support many concurrently waiting Agent, Workflow, ToolInvocation,
and MultiAgent lifecycles without allocating one OS Thread per logical task.
At the same time, application and third-party code may contain synchronous work
that must not execute on the single Runtime EventLoop thread.

The architecturally relevant distinction is whether a unit of work can safely run
to completion on EventLoop or must be moved off the control thread. The way work
executes is separate from the object used by callers to observe completion.

## Decision

Framework lifecycle coordination uses one Runtime-owned EventLoop and explicit
FSMSession state/events. **`Phronomy::Task` is the single caller-facing completion
handle**, not an execution backend.

There are two framework execution mechanisms:

- **EventLoop / FSMSession** for logical lifecycle progression and waits;
- **OffloadPool** for synchronous work that must execute on bounded worker OS
  Threads away from EventLoop.

Both mechanisms surface asynchronous completion as `Phronomy::Task`.

Phronomy defines two Tool execution modes:

- `:cooperative` — short, EventLoop-safe work, or a specialized asynchronous
  implementation that starts another Phronomy lifecycle and immediately returns
  a Task;
- `:offloaded` — synchronous work that must not run on EventLoop. It executes in
  the bounded OffloadPool and returns a Task.

Workload classification such as I/O-bound versus CPU-bound is application-owned.
Phronomy does not provide separate `:blocking_io`, `:cpu_bound`, or
`:external_process` Tool execution modes.

Logical waits are never offloaded merely to obtain concurrency. Waiting for an
Agent, Workflow, ToolInvocation, approval, timer, or another Task is represented
as FSMSession state plus a later EventLoop event.

## Runtime model

```text
Runtime
├─ EventLoop (one control-plane OS Thread)
│  └─ FSMSession
│     ├─ Agent
│     ├─ Workflow
│     ├─ ToolInvocation
│     └─ MultiAgent fan-out
├─ OffloadPool (bounded OS Threads)
│  ├─ private Operation records
│  ├─ blocking I/O
│  ├─ CPU-bound synchronous work
│  └─ other long synchronous work
├─ named OffloadPools
└─ EventLoop-driven timers

EventLoop / FSMSession ─┐
                       ├─> Task = completion handle
OffloadPool ────────────┘
```

OffloadPool's private Operation record owns the submitted block, queue/worker
state, submit-time timeout/cancellation linearization, wait-time accounting, and
abandonment. It is not returned to application or extension code.

## Capacity and starvation

The default OffloadPool is a shared bounded resource. Phronomy guarantees bounded
worker count, bounded queue depth, backpressure, timeout/cancellation settlement,
abandoned-worker accounting, metrics, and lifecycle shutdown. It does not
guarantee work-class fairness, CPU isolation, core reservation, or CPU-bound
speedup.

Applications own capacity planning through `offload_pool_size` and
`offload_queue_size`. Where isolation is required, applications may use
`Runtime#pool(name, size:, queue_size:)` to create independent named OffloadPool
resource domains.

## EventLoop admission rule

An EventLoop action must not block while waiting for a free OffloadPool queue
slot. Framework-owned EventLoop-origin submissions therefore use non-blocking
admission (`on_full: :raise`) and propagate `BackpressureError` through the normal
FSM/Task completion path.

## Timeout and cancellation

An OffloadPool submit-time timeout settles the caller-facing Task with
`TimeoutError`. It does not asynchronously interrupt a running worker Thread. If
execution has already started, the private Operation becomes abandoned, the
worker may continue until the submitted synchronous call returns, and that
eventual worker result is discarded.

The cancellation token passed to `OffloadPool#submit` follows the same model:

- cancellation before worker execution prevents the submitted block from
  starting and settles the Task as cancelled;
- cancellation after worker execution starts settles the Task immediately, marks
  the private Operation abandoned, and allows the worker to continue;
- cancellation does not use `Thread#raise`;
- application code may observe the same CancellationToken and terminate its own
  synchronous operation cooperatively.

A submit token with a monotonic deadline is connected to the Runtime timer queue,
so deadline expiry becomes explicit cancellation without a polling Thread.

`Task#wait_result(timeout:)` is a synchronous bridge for non-EventLoop callers.
Its timeout is waiter-local: it raises `TimeoutError` only to that caller and does
not settle the Task, cancel the submitted operation, or mark an OffloadPool
Operation abandoned.

Framework components own Task settlement. Application code should request
operation-wide cancellation through the CancellationToken accepted by the API
that created the Task rather than calling Task settlement methods directly. A
Task cancellation must not implicitly cancel a shared CancellationToken in the
reverse direction.

Independent `Task#on_complete` notification callbacks are fault-isolated. Their
execution thread is not guaranteed, so callbacks must be thread-safe and should
return quickly. Framework lifecycle code normally converts completion into an
explicit EventLoop event.

## Abandoned-worker metrics

`offload_pool_abandoned_total` is cumulative: it counts operations whose
caller-facing timeout or cancellation won after worker execution had already
started. `offload_pool_abandoned_active` is current-state: it counts only those
abandoned operations whose synchronous workers are still occupying OffloadPool
capacity. Task does not expose abandonment as caller-facing completion state;
that distinction remains private OffloadPool execution/observability state.

## CPU-bound work

CPU-bound work is allowed through `:offloaded`. Thread offload protects the
EventLoop from direct long synchronous execution but does not remove CRuby GVL
contention or physical CPU contention.

A future subprocess capability may provide process isolation and hard process
termination. That future implementation belongs to the offload subsystem and
does not reintroduce a Tool-level workload class.

## Genuine native async

A component that truly uses a native asynchronous driver and does not create a
Phronomy-owned OS Thread does not need an OffloadPool worker. If such an
extension point is formally introduced, it must still adapt completion into a
`Phronomy::Task`; it must not expose provider-specific futures or private Runtime
operation records as Phronomy's completion contract.

The current VectorStore and Embeddings extension contracts are synchronous; their
framework-provided async convenience methods use OffloadPool.

## Prohibited pattern

```text
OffloadPool worker
  → child_agent.invoke_async
  → wait_result
```

and equivalently for Workflow/ToolInvocation/Task lifecycles.

The correct model is:

```text
parent FSMSession
  → start child lifecycle
  → return Task immediately
  → child settles
  → post parent EventLoop event
```

## Consequences

- There is one explicit framework continuation model: FSMSession + EventLoop.
- There is one caller-facing completion abstraction: Task.
- Task stays thread-free and represents settlement only.
- OffloadPool owns bounded OS-thread execution and its private Operation state.
- Tool execution classification remains `:cooperative` / `:offloaded`.
- CPU/I/O classification and resource sizing are application responsibilities.
- Production Fiber execution is not part of the architecture.
- Raw production Threads remain confined to EventLoop and OffloadPool.
