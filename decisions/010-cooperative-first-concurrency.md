# ADR-010: Cooperative-First Concurrency — BlockingAdapterPool for Uncontrollable I/O

## Status

Accepted

## Context

Phronomy provides its own concurrency primitives:

- **`Phronomy::Runtime`** — task scheduler; backend is configurable
  (`:cooperative` = `FakeScheduler` / `ImmediateBackend` by default,
  `:thread` = `ThreadScheduler` / `ThreadBackend` for opt-in parallelism).
- **`Phronomy::EventLoop`** — singleton event dispatcher; drives the cooperative
  task cycle.

Early implementations occasionally forced `ThreadBackend` inside framework
components (e.g., `Agent::FSM#spawn_agent_task` in commit `0cb8510`) to work
around a perceived limitation: if an agent makes a blocking I/O call with the
cooperative backend active, it blocks the calling thread.

This approach was identified as wrong for two reasons:

1. **Misplaced responsibility** — threading the *application's* I/O at the
   *framework* layer prevents the `runtime_backend` configuration from being
   honored and removes the app developer's control over the concurrency model.
2. **Violation of layering** — the framework should not assume that its callers
   are cooperative-scheduler-aware; it should provide primitives and let the
   caller decide the backend.

There is a separate, legitimate category of blocking I/O: third-party gems
(RubyLLM, ActiveRecord, Redis, Faraday, etc.) that perform blocking system
calls internally and cannot be made non-blocking from the Phronomy side.
These must be handled differently from application-controlled I/O.

## Decision

### Rule 1 — Cooperative-first for core control

The core control flow of every Phronomy component — **Agent, Workflow, Tool
orchestration, Orchestrator, RAG pipeline, Streaming** — MUST be implemented
using cooperative task / event / scheduler primitives:

```
Runtime.instance.spawn(name: "...") { ... }   # respects configured backend
EventLoop.instance.post { ... }               # event dispatch
```

Do NOT force `ThreadBackend` or `ThreadScheduler` inside framework components
unless Rule 2 explicitly applies.

### Rule 2 — ThreadScheduler only for framework-owned infinite loops

A framework component MAY use a dedicated `ThreadScheduler` (or `ThreadBackend`)
if and only if **not** threading would unconditionally block the framework's own
infinite loop.

The only current example satisfying this criterion:

```ruby
# EventLoop#start — the run_loop is the framework's own infinite dispatch loop.
# It MUST run in its own thread; the cooperative backend cannot yield itself.
thread_runtime = Phronomy::Runtime.new(
  scheduler: Phronomy::Runtime::ThreadScheduler.new
)
@task = thread_runtime.spawn(name: "event-loop") { run_loop }
```

All other framework components — including FSM, orchestration, RAG, streaming —
do NOT own an infinite loop and therefore MUST use `Runtime.instance.spawn`.

### Rule 3 — BlockingAdapterPool for uncontrollable blocking I/O

Third-party gems whose internal I/O Phronomy cannot control (RubyLLM, ActiveRecord,
Redis client, Faraday, etc.) MUST be isolated behind a bounded
`BlockingAdapterPool`.

```
           ┌─────────────────────────────────────┐
           │  Cooperative EventLoop / Runtime     │
           │  (FakeScheduler, ImmediateBackend)   │
           │                                     │
           │  Agent ──► BlockingAdapterPool ──► RubyLLM (HTTP)
           │  RAG   ──► BlockingAdapterPool ──► ActiveRecord / Redis
           └─────────────────────────────────────┘
                              │
                    ┌─────────┴─────────┐
                    │  Thread pool      │  ← bounded (max_threads:)
                    │  (OS threads)     │
                    └───────────────────┘
```

Properties of `BlockingAdapterPool`:
- Uses OS threads internally (they are the correct tool for I/O that releases
  the GVL).
- **Always bounded** — configurable `max_threads:` (no unbounded `Thread.new`).
- Returns a `Phronomy::Task`-compatible future so the cooperative layer can
  await results without blocking the EventLoop.
- Is the **only** place in the framework that creates raw threads for I/O.

> **Note:** `dispatch_parallel` (ADR-008) currently creates one thread per
> sub-agent via `Thread.new`. This predates the `BlockingAdapterPool` concept
> and is a candidate for future migration. Until that migration, it remains an
> accepted exception per ADR-008.

## Consequences

### Positive
- The `runtime_backend` configuration is respected throughout; `:cooperative`
  truly means cooperative for all framework-controlled paths.
- Thread creation is isolated and bounded; no accidental unbounded thread
  proliferation from deep inside the framework.
- The concurrency model is layered and explicit:
  cooperative layer → adapter boundary → bounded thread pool → blocking gem.
- Tests can reliably use `FakeScheduler` by default and opt in to `:thread`
  only where true concurrency is required.

### Negative / Tradeoffs
- `BlockingAdapterPool` is not yet implemented (as of ADR-010 acceptance).
  Until it is, callers that need real blocking I/O must opt in to `:thread`
  backend explicitly (e.g., in tests via `around` blocks).
- `dispatch_parallel` remains on raw threads (ADR-008) until migrated.

## Derived Checklist

When writing or reviewing any Phronomy component, apply this checklist:

| Question | Correct action |
|---|---|
| Does this component own a `while true` / `loop do` that blocks forever? | May use dedicated `ThreadScheduler` (Rule 2) |
| Does this component call into app/agent code (LLM, tools)? | `Runtime.instance.spawn` — no ThreadBackend (Rule 1) |
| Does this component call a blocking gem (RubyLLM, AR, Redis)? | Route through `BlockingAdapterPool` (Rule 3) |
| Is this a test that needs real concurrency (sleep + cancel)? | `around` block with `c.runtime_backend = :thread` opt-in |
| Anything else | Default: `Runtime.instance.spawn` |

## Related ADRs

- ADR-008: Orchestrator Uses OS Threads for Parallel Dispatch (predates this
  ADR; `dispatch_parallel` is a future migration candidate)
