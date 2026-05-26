# ADR-010: Cooperative-First Concurrency — BlockingAdapterPool for Uncontrollable I/O

## Status

Accepted — updated 2026-05-25 to document current scheduler landscape and
production-cooperative roadmap (Issues #331, #332, #334).

## Context

Phronomy provides its own concurrency primitives:

- **`Phronomy::Runtime`** — task scheduler; backend is configurable.
  The current production default is `:thread` (`ThreadScheduler` / `ThreadBackend`).
  See the backend landscape table below for all supported values.
  *(Historical note: early versions used `:cooperative` as the default; it is now
  a deprecated alias for `:immediate`.)*
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

### Runtime backend landscape

| Backend | Scheduler class | Role | Production use? |
|---------|-----------------|------|----------------|
| `:thread` | `ThreadScheduler` / `ThreadBackend` | **Default.** One OS thread per task. Provides true parallelism for blocking I/O workflows. | Yes |
| `:immediate` | `FakeScheduler` / `ImmediateBackend` | **Unit test double.** Tasks run synchronously on the caller's thread; no extra threads. | Tests only |
| `:fiber` | `DeterministicScheduler` / `FiberBackend` | **Experimental validation backend.** Runs tasks as Ruby Fibers to verify that framework components are truly non-blocking. Use in CI to catch inadvertent blocking; never use in production. Not a planned production replacement for `:thread`; preemptive scheduling will not be added. | No |

Note: `:cooperative` is a deprecated alias for `:immediate` and must not be used in new code.

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

**Legitimate ThreadScheduler exceptions (exhaustive list):**

| Component | Reason |
|---|---|
| `EventLoop#start` | `run_loop` is the framework's own `while @running` infinite dispatch loop; running it on the shared scheduler would consume the scheduler, preventing all other tasks from running |

**Handler constraints for EventLoop:**

- Handler code runs **on the EventLoop thread**.  Do not perform blocking
  operations (database, LLM, HTTP) directly inside a handler — this stalls all
  session processing.
- Do **not** call `Workflow#invoke` from within a handler.  That call blocks
  until the EventLoop processes events, causing a deadlock.  Use the async
  pattern: schedule work via `Runtime.instance.spawn` or `BlockingAdapterPool`,
  then post results back with `EventLoop#post`.

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

## Scheduler Landscape (as of 2026-05-25)

Three scheduler backends currently exist:

| Symbol / Class | Status | Purpose |
|---|---|---|
| `:thread` — `ThreadScheduler` / `ThreadBackend` | **Production default** | One OS thread per task; GVL-releasing I/O works transparently |
| `:immediate` — `FakeScheduler` / `ImmediateBackend` | Test / CI | Synchronous; block runs to completion before `spawn` returns; no threads |
| `:fiber` — `DeterministicScheduler` / `FiberBackend` | **Experimental validation backend** | Tick-based Fiber scheduler with virtual clock; enables deterministic concurrency tests without wall-clock timers. Named backend added in Issue #334. |

### `:cooperative` deprecation

`:cooperative` was a silent alias for `:immediate` (mapped to `FakeScheduler`).
As of Issue #332, it now emits a `WARN`-level deprecation message and must not
be used in new code. Issue #334 introduced `:fiber` as the named experimental
validation backend; `:cooperative` is retained only for backwards compatibility.

### DeterministicScheduler as a stepping stone

`DeterministicScheduler` is the foundation for the long-term production
cooperative runtime goal. It provides:

- Ready-queue dispatch, virtual timer heap, scheduler signal API
- `FiberBackend` wrapping tasks as Fibers
- `tick` / `run_until_idle` / `advance(seconds)` for deterministic test control

**Remaining gaps versus a full production cooperative runtime:**

- No real-wall-clock timer integration (`TimerQueue` runs as a background thread — Issue #331)
- No `BlockingAdapterPool` integration for LLM/network calls (Issue #280)
- Scheduler must be driven manually (`tick`) rather than event-loop-driven

The minimum delta to promote `DeterministicScheduler` to production use:

1. Integrate `TimerQueue` into the scheduler `tick` cycle (eliminates timer thread — Issue #331)
2. Implement `BlockingAdapterPool` and wire LLM/tool calls through it (Issue #280)
3. ~~Expose as a named `runtime_backend` (`:fiber`)~~ — **done** (Issue #334)
4. Add real-wall-clock integration (replace virtual time with `Process.clock_gettime`)

Progress is tracked in Issues #331 and #280.

### TimerQueue background thread

`Runtime::TimerQueue` currently runs as a dedicated background OS thread
(`Thread.new { run_loop }`). This is an accepted interim implementation — it is
robust for production but violates the cooperative-first goal. The long-term
target is to integrate timer firing into the scheduler's own `tick` cycle so
that no separate timer thread is needed. Progress tracked in Issue #331.

## Consequences

### Positive
  truly means cooperative for all framework-controlled paths.
- Thread creation is isolated and bounded; no accidental unbounded thread
  proliferation from deep inside the framework.
- The concurrency model is layered and explicit:
  cooperative layer → adapter boundary → bounded thread pool → blocking gem.
- Tests can reliably use `FakeScheduler` by default and opt in to `:thread`
  only where true concurrency is required.
- `DeterministicScheduler` + `FiberBackend` provide a deterministic test
  foundation for cooperative concurrency without wall-clock timers.

### Negative / Tradeoffs
- `BlockingAdapterPool` is not yet implemented (as of ADR-010 acceptance).
  Until it is, callers that need real blocking I/O must opt in to `:thread`
  backend explicitly (e.g., in tests via `around` blocks).
- `dispatch_parallel` remains on raw threads (ADR-008) until migrated.
- `TimerQueue` runs as a background OS thread (interim; see Issue #331).
- `DeterministicScheduler` backs the named `:fiber` backend (Issue #334
  resolved). It remains experimental and not for production use; the remaining
  steps toward a full production cooperative runtime are `TimerQueue`
  integration (Issue #331) and `BlockingAdapterPool` completion (Issue #280).

## Derived Checklist

When writing or reviewing any Phronomy component, apply this checklist:

| Question | Correct action |
|---|---|
| Does this component own a `while true` / `loop do` that blocks forever? | May use dedicated `ThreadScheduler` (Rule 2) |
| Does this component call into app/agent code (LLM, tools)? | `Runtime.instance.spawn` — no ThreadBackend (Rule 1) |
| Does this component call a blocking gem (RubyLLM, AR, Redis)? | Route through `BlockingAdapterPool` (Rule 3) |
| Is this a test that needs real concurrency (sleep + cancel)? | `around` block with `c.runtime_backend = :thread` opt-in |
| Anything else | Default: `Runtime.instance.spawn` |

## Related ADRs and Issues

- ADR-008: Orchestrator Uses OS Threads for Parallel Dispatch (predates this
  ADR; `dispatch_parallel` is a future migration candidate)
- Issue #331: TimerQueue scheduler integration (long-term — eliminate timer thread)
- Issue #334: Promote DeterministicScheduler to production cooperative runtime
- Issue #332: `:cooperative` alias deprecation (resolved 2026-05-25)
- Issue #280: MCP transports behind BlockingAdapterPool (pending)

## Non-goals

The following capabilities are intentionally out of scope for this framework's
concurrency layer:

- **CPU-bound process pool** — A `ProcessPoolExecutor` equivalent is not part
  of core framework by default. CPU-intensive tool work belongs at the
  application layer (fork, Sidekiq, etc.). A separate ADR would be required
  to introduce one.
- **External process manager** — Spawning, monitoring, or restarting external
  subprocesses is not currently a framework responsibility. A separate ADR
  would be required.
- **Preemptive scheduling** — The cooperative-first model is non-preemptive by
  design. Introducing a preemptive scheduler or promoting `:fiber` to
  production default is not currently planned; a separate ADR would be required.
- **Additional ToolExecutor core execution routes** — Only `:cooperative` and
  `:blocking_io` are core dispatch routes. `:cpu_bound` and `:external_process`
  are compatibility aliases that fall back to `:blocking_io` with a warning.
  Any genuinely new core execution route requires a new ADR.

