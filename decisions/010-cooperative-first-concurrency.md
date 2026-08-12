# ADR-010: EventLoop / FSMSession First Concurrency

## Status

Accepted — revised 2026-08-13.

This revision supersedes the earlier scheduler-backend roadmap that described
`Runtime#spawn`, `ThreadBackend`, `FiberBackend`, `FakeScheduler`,
`DeterministicScheduler`, and configurable `runtime_backend` values. Those
execution mechanisms have been removed from the active architecture.

The architectural intent remains cooperative control: framework lifecycle work
must never require one OS thread per logical task.

## Context

Phronomy coordinates long-lived Agent, Workflow, Tool, and MultiAgent lifecycles.
Most of those lifecycles spend significant time waiting for something else:

- an LLM HTTP response;
- a Tool result;
- a child Agent;
- human approval;
- a timer or cancellation deadline;
- another application event.

A waiting lifecycle does not itself require an execution thread. Its continuation
can be represented explicitly by FSM state plus a later EventLoop event.

There are, however, third-party calls whose implementation performs ordinary
blocking I/O (RubyLLM/HTTP, database clients, Redis, MCP transports, etc.). Those
calls cannot safely execute on the EventLoop thread and therefore require a
bounded worker-thread boundary.

## Decision

### 1. EventLoop is the control plane

Phronomy has one Runtime-owned `EventLoop`. It owns one dedicated OS thread and
serially dispatches short events to `FSMSession` instances.

```text
Runtime
  |
  +-- EventLoop -------------------- one dedicated OS Thread
  |     |
  |     +-- Agent FSMSession
  |     +-- Workflow FSMSession
  |     +-- ToolInvocation FSMSession
  |     +-- MultiAgent/FanOut FSMSession
  |
  +-- BlockingAdapterPool --------- bounded OS worker Threads
  |
  +-- TimerQueue ------------------ threadless; EventLoop-driven
```

FSM actions must return quickly. Waiting is represented by a state transition
and later event, not by blocking the EventLoop thread.

### 2. Task is a completion handle, not an executor

`Phronomy::Task` represents asynchronous completion only:

- pending/completed/failed/cancelled state;
- result/error;
- `on_complete` callbacks;
- cancellation propagation;
- blocking `wait_result` for external callers;
- result mapping.

`Task` does not own a Thread, Fiber, Scheduler, execution block, or CPU time
slice. `Task#wait_result` is forbidden while on the EventLoop thread unless the
Task is already settled.

### 3. BlockingAdapterPool is only for unavoidable blocking I/O

Blocking I/O that Phronomy cannot make non-blocking is submitted to a bounded
`BlockingAdapterPool`.

Examples:

- RubyLLM/provider HTTP requests;
- database clients with blocking drivers;
- Redis clients with blocking drivers;
- MCP transports or other blocking third-party libraries;
- application Tools explicitly declaring `execution_mode :blocking_io`.

A worker Thread must **not** be consumed merely to wait for another Phronomy
Task, Agent, Workflow, timer, or FSM. Those are logical asynchronous waits and
must return to EventLoop.

### 4. Tool execution contract

`Agent::Context::Capability::Base.execution_mode` has four values:

#### `:cooperative`

The Tool is EventLoop-safe: ordinary `execute` work must be short and must not
perform blocking I/O or an unbounded CPU computation.

For a normal cooperative Tool, `call_async` executes the short call inline and
returns an already-settled `Task`.

A specialized cooperative Tool may itself start framework-owned asynchronous
work and return a completion handle immediately. Agent-as-Tool uses this form:

```text
parent ToolInvocation :running
        |
        +-- child_agent.invoke_async(...)
        |       |
        |       +-- child Agent FSMSession on EventLoop
        |               |
        |               +-- blocking provider I/O -> BlockingAdapterPool
        |
        +-- return immediately

child completion Task
        |
        +-- ToolInvocation :execution_completed event
```

No BlockingAdapterPool worker is held while waiting for the child Agent.

#### `:blocking_io`

The Tool executes on `BlockingAdapterPool`. Its completion callback posts the
result back to ToolInvocation's FSM.

#### `:cpu_bound`

Not executed by EventLoop and not silently redirected to BlockingAdapterPool.
Phronomy currently has no CPU executor; declaring this mode raises a
configuration error. A future process/Ractor/CPU executor requires a separate
architecture decision.

#### `:external_process`

Not executed implicitly by the core runtime. A dedicated process executor is a
future concern and requires a separate architecture decision.

### 5. Agent-as-Tool is event-driven

An Agent Tool can take a long time, but the elapsed time is predominantly a
logical lifecycle composed of child FSM states and blocking provider calls.
That makes it suitable for EventLoop/FSM coordination.

The parent ToolInvocation starts `child_agent.invoke_async` and retains only a
completion handle. When the child settles, the result is converted to an
`:execution_completed` event for the parent ToolInvocation.

The following implementation is prohibited:

```text
BlockingAdapterPool worker
    -> child_agent.invoke_async
    -> wait_result                # prohibited logical wait on worker
```

This prohibition prevents pool starvation where all workers wait for child
Agents that themselves need the same pool for LLM or Tool I/O.

### 6. MultiAgent fan-out is event-driven

`dispatch_parallel` and `fan_out` coordinate child Agents with a FanOut
FSMSession. `max_concurrency` limits the number of live child Agent invocations,
not the number of OS threads.

Child completion callbacks post parent events. No per-child `Thread.new`,
`Runtime#spawn`, or Task execution backend is used.

### 7. TimerQueue is threadless

`TimerQueue` stores monotonic deadlines only. EventLoop computes the next timer
wait, wakes when a new earlier timer is registered, and fires due callbacks.
There is no timer Thread.

Timer callbacks follow the same short-dispatch rule as other EventLoop actions.

### 8. Production Thread/Fiber boundary

Raw production OS Threads are permitted only in the following two locations:

| Location | Reason |
|---|---|
| `EventLoop` | Framework-owned infinite dispatch loop |
| `BlockingAdapterPool` | Bounded execution of unavoidable blocking I/O |

Production Agent/Workflow/Tool/MultiAgent code must not create raw Threads.

Production Fiber execution is not part of the architecture. There is no
`FiberBackend`, Fiber scheduler, or runtime backend selector.

Application code may of course create its own Threads for application-owned
work, but that is outside Phronomy's lifecycle execution model.

## Long-running work classification

When introducing a long-running operation, classify it before choosing an
execution mechanism:

| Work | Correct mechanism |
|---|---|
| Waiting for child Agent/Workflow/approval/timer/event | FSM state + EventLoop event |
| Blocking HTTP/DB/Redis/MCP/file/network library | BlockingAdapterPool |
| Short pure computation | EventLoop action / ordinary method |
| Long CPU-bound computation | Dedicated CPU/process executor (not currently provided) |
| External process lifecycle | Dedicated process executor (not currently provided) |

Elapsed wall-clock time alone is not a reason to use BlockingAdapterPool. The
question is whether an OS thread is actually blocked executing an uncontrollable
blocking call.

## Shutdown

Runtime shutdown has two distinct phases:

1. drain admitted FSMSessions within the configured drain deadline;
2. enqueue EventLoop STOP and join the dedicated EventLoop Thread with its own
   short stop grace.

Normal completion decrements outstanding session accounting before waking a
blocking external caller. A healthy shutdown therefore does not consume the
full configured grace period for every invocation or test.

## Consequences

### Positive

- Agent/Workflow/Tool/MultiAgent share one explicit continuation model.
- Logical waits consume no OS worker Thread.
- Blocking thread count and queue depth are bounded and observable.
- Pool starvation caused by parent work waiting synchronously for child Agents
  is avoided.
- Runtime no longer maintains duplicate Thread/Fiber/Immediate scheduler
  implementations.
- Timers require no extra Thread.
- Tests exercise the same EventLoop control model as production.

### Tradeoffs

- FSM/event-driven code must explicitly model asynchronous continuation.
- A Tool incorrectly declared `:cooperative` can still stall EventLoop; dispatch
  duration diagnostics are therefore important.
- CPU-bound and external-process execution currently require application-owned
  infrastructure or a future dedicated executor.
- Synchronous public APIs remain blocking wrappers and must not be called from
  EventLoop callbacks.

## Derived review checklist

1. Does this code wait for another Phronomy lifecycle? Use an FSM/event, not a
   worker Thread.
2. Does it call a genuinely blocking external library? Use
   `BlockingAdapterPool`.
3. Does a Tool declare `:cooperative`? Its synchronous work must return quickly,
   or its `call_async` must start another framework lifecycle and return a
   completion handle immediately.
4. Does production code contain `Thread.new`? It must be EventLoop or
   BlockingAdapterPool.
5. Does production code contain Fiber execution or `Runtime#spawn`? Reject it.
6. Does EventLoop code call `wait_result`, `join`, blocking I/O, or long CPU
   work? Reject it.

## Historical note

Earlier revisions of ADR-010 described configurable `:thread`, `:immediate`, and
`:fiber` runtime backends. Those were transitional mechanisms while the
framework's event-driven lifecycle architecture was incomplete. They are no
longer active APIs or implementation targets.

ADR-008's per-subagent OS-thread dispatch decision is superseded by the FanOut
FSMSession implementation.
