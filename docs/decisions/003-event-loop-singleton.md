# ADR-003: EventLoop Is a Process-Wide Singleton

## Status

Accepted

## Context

The `EventLoop` routes asynchronous events (tool results, child completions,
timeouts) between concurrent agent invocations. The design choices were:

1. **Per-agent event loop**: each `Agent::Base#invoke` owns its own event loop
   thread.
2. **Per-`Orchestrator` event loop**: one loop per orchestrator instance.
3. **Process-wide singleton**: one `EventLoop` serves all concurrent
   invocations in the process.

Per-agent loops would require creating and tearing down threads on every
`invoke` call. In Rails / Puma environments where multiple requests invoke
agents concurrently, this creates significant thread churn. Per-orchestrator
loops are better, but `Orchestrator` instances are often short-lived, and
coordinating parent-child event delivery across loop boundaries is complex.

Ruby's GVL means true parallelism is limited to I/O-bound work, so the
throughput gain from per-agent loops would be minimal. A singleton loop with a
thread-safe queue is simpler and avoids inter-loop coordination.

## Decision

`Phronomy::EventLoop` is implemented as a process-wide singleton that runs on a
dedicated background thread. Agents post events to a shared `Queue`; the loop
dispatches them to registered handlers (identified by `target_id`).

## Consequences

**Positive:**
- Single background thread; no thread churn per invocation.
- Cross-agent event delivery (e.g., child-to-parent completion) is natural
  because all agents share the same loop.
- Startup/shutdown logic is simple (one thread to manage).

**Negative / Tradeoffs:**
- The singleton is global mutable state; tests must call
  `Phronomy.reset_runtime!` between examples.
- A bug in the event loop (or a blocking handler) affects all concurrent
  invocations, not just one agent.
- In multi-process environments (e.g., Sidekiq workers), each process has its
  own singleton — cross-process event delivery is not supported.
