# ADR-010: EventLoop / FSMSession First Concurrency

## Status

Accepted — revised for the OffloadPool execution boundary.

## Context

Phronomy must support many concurrently waiting Agent, Workflow, ToolInvocation,
and MultiAgent lifecycles without allocating one OS Thread per logical task.
At the same time, application and third-party code may contain synchronous work
that must not execute on the single Runtime EventLoop thread.

Classifying arbitrary application work as I/O-bound, CPU-bound, or external
process work is not a responsibility the framework can reliably infer. The
architecturally relevant distinction for Phronomy is whether a unit of work can
safely run to completion on EventLoop or must be moved off the control thread.

## Decision

Framework lifecycle coordination uses one Runtime-owned EventLoop and explicit
FSMSession state/events. **Task is a completion handle**, not an execution
backend.

Phronomy defines two Tool execution modes:

- `:cooperative` — short, EventLoop-safe work, or a specialized asynchronous
  implementation that starts another Phronomy lifecycle and immediately returns
  a completion handle.
- `:offloaded` — synchronous work that must not run on EventLoop. It executes in
  the bounded `OffloadPool`.

`OffloadPool` is the thread execution boundary for synchronous work that must be
kept off EventLoop. It may contain blocking I/O, CPU-bound Ruby work, or other
application-defined long-running synchronous calls.

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
│  ├─ blocking I/O
│  ├─ CPU-bound synchronous work
│  └─ other long synchronous work
├─ named OffloadPools
└─ EventLoop-driven timers

Task = completion handle
```

## Capacity and starvation

The default OffloadPool is a shared bounded resource. CPU-heavy work can occupy
slots that would otherwise be available to I/O, and slow I/O can do the same in
reverse. Phronomy guarantees bounded worker count, bounded queue depth,
backpressure, timeout/cancellation settlement, abandoned-worker accounting,
metrics, and lifecycle shutdown. It does **not** guarantee work-class fairness,
CPU isolation, core reservation, or CPU-bound speedup.

Applications own capacity planning through `offload_pool_size` and
`offload_queue_size`. Where isolation is required, applications may use
`Runtime#pool(name, size:, queue_size:)` to create independent named OffloadPool
resource domains.

## EventLoop admission rule

An EventLoop action must not block while waiting for a free OffloadPool queue
slot. Framework-owned EventLoop-origin submissions therefore use non-blocking
admission (`on_full: :raise`) and propagate `BackpressureError` through the
normal FSM/completion path.

External management threads may deliberately choose other admission policies
when blocking the caller is acceptable.

## Timeout and cancellation

An OffloadPool submit-time timeout settles the caller-facing PendingOperation.
It does not asynchronously interrupt a running worker Thread. If execution has
already started, the operation becomes abandoned, the worker may continue until
the submitted synchronous call returns, and that eventual worker result is
discarded.

The cancellation token passed to `OffloadPool#submit` follows the same
caller-facing settlement model:

- cancellation before worker execution prevents the submitted block from
  starting;
- cancellation after worker execution starts settles the caller-facing
  PendingOperation immediately, marks the operation abandoned, and allows the
  worker to continue until the synchronous call returns;
- cancellation does not use `Thread#raise`;
- application code may observe the same CancellationToken and terminate its own
  synchronous operation cooperatively.

A submit token with a monotonic deadline is connected to the Runtime timer queue,
so deadline expiry becomes explicit cancellation without a polling Thread.

`PendingOperation#blocking_wait(timeout:)` is a low-level synchronous bridge for
non-EventLoop callers such as tests and diagnostics. Its timeout is waiter-local:
it raises `TimeoutError` only to that caller and does not settle the
PendingOperation, cancel the submitted operation, or mark it abandoned.
PendingOperation does not define a waiter-local cancellation token;
operation-wide cancellation is represented only by the token passed to
`OffloadPool#submit`.

Independent notification callbacks are fault-isolated. A `StandardError` from one
`CancellationToken#on_cancel`, `Task#on_complete`, or
`PendingOperation#on_complete` subscriber is logged and does not suppress later
subscribers. This rule applies to notification fan-out; continuation or
transformation callbacks still report their own failures through the operation
they construct.

`abandoned_count` and the exported `offload_pool_abandoned_total` metric are
cumulative: they count operations whose caller-facing submit timeout or submit
cancellation settled after worker execution had already started.
`abandoned_active_count` and `offload_pool_abandoned_active` are current-state
values: they count only abandoned operations whose synchronous worker is still
occupying OffloadPool capacity.

## CPU-bound work

CPU-bound work is allowed through `:offloaded`. Thread offload protects the
EventLoop from direct long synchronous execution but does not remove CRuby GVL
contention or physical CPU contention. Those are explicitly outside the core
OffloadPool guarantee.

A future subprocess capability may provide process isolation, hard process
termination, stdout/stderr capture, and CPU-worker separation. That future
implementation belongs to the offload subsystem and does not reintroduce a
Tool-level `:external_process` execution class.

## Prohibited pattern

```text
OffloadPool worker
  → child_agent.invoke_async
  → wait_result
```

and equivalently for Workflow/ToolInvocation/Task lifecycles.

That pattern converts a logical wait into worker-slot occupancy and can create
pool starvation. The correct model is:

```text
parent FSMSession
  → start child lifecycle
  → return completion handle immediately
  → child settles
  → post parent EventLoop event
```

## Consequences

- There is one explicit framework continuation model: FSMSession + EventLoop.
- `Task` stays thread-free and represents settlement only.
- Tool execution classification becomes `:cooperative` / `:offloaded`.
- CPU/I/O classification and resource sizing are application responsibilities.
- Named pools remain available for application-managed resource isolation.
- Production Fiber execution is not part of the architecture.
- Raw production Threads remain confined to EventLoop and OffloadPool.
