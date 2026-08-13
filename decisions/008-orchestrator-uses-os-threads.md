# ADR-008: Orchestrator Uses OS Threads for Parallel Dispatch

## Status

**Superseded by ADR-010 on 2026-08-13.**

This file is retained as decision history. Its original implementation — one OS
Thread per `dispatch_parallel` child — is no longer the active architecture.

## Historical context

The original Orchestrator implementation needed concurrent subagent execution
before Phronomy had a common EventLoop/FSMSession control model. It therefore
used `Thread.new` per child Agent, optionally bounded by `max_concurrency`.

That choice provided straightforward parallelism for I/O-heavy Agent calls but
also tied logical child concurrency directly to OS-thread count.

## Superseding decision

Phronomy now models fan-out as a parent `FanOutInvocation` / FSMSession:

```text
FanOut FSMSession
    |
    +-- start child Agent A asynchronously
    +-- start child Agent B asynchronously
    +-- start child Agent C asynchronously
    |
    +-- child completion events
    |
    +-- aggregate / fail / timeout / cancel
```

`max_concurrency` limits how many child Agent invocations are active. It does
not create a corresponding set of Threads.

Each child Agent runs through the common Agent FSMSession/EventLoop lifecycle.
When a child performs synchronous work that must not run on EventLoop, only that
synchronous operation is executed on the bounded `OffloadPool`.

Therefore:

- `dispatch_parallel` does not create raw Threads;
- no `Runtime#spawn` or Task execution backend is involved;
- child completion is delivered by EventLoop events;
- result ordering, fail/skip policy, timeout, and cancellation belong to the
  FanOut state machine.

See ADR-010 for the current concurrency model and Thread boundary.
