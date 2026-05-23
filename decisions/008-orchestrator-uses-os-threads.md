# ADR-008: Orchestrator Uses OS Threads for Parallel Dispatch

## Status

Accepted

## Context

`Agent::Orchestrator#dispatch_parallel` runs multiple sub-agent invocations
concurrently. The Ruby concurrency primitives available are:

1. **OS threads** (`Thread`): true OS-level threads, subject to Ruby's GVL for
   CPU-bound work, but I/O-bound work (LLM API calls, tool HTTP requests)
   releases the GVL and runs in parallel.
2. **Ractors**: actor-model isolation, no shared mutable state between Ractors.
   True parallel for CPU-bound work but requires strict object isolation.
3. **Fibers / async**: cooperative concurrency via Fiber scheduler (e.g.,
   `async` gem). Non-blocking I/O without multiple threads.
4. **`concurrent-ruby` thread pool**: managed pool of OS threads.

LLM calls and tool invocations are overwhelmingly I/O-bound (HTTP requests).
Under the GVL, OS threads are sufficient to achieve meaningful parallelism for
these workloads. Ractors require that all objects passed between them are
shareable, which is incompatible with RubyLLM's mutable chat objects and
`WorkflowContext` instances without significant refactoring.

Fibers require an async-compatible HTTP library stack throughout (RubyLLM,
Faraday, etc.), which is not guaranteed today.

## Decision

`dispatch_parallel` spawns one OS thread per task using Ruby's `Thread.new`.
A `max_concurrency:` cap (default: unlimited) uses a `Mutex`-guarded counter to
limit the number of simultaneously active threads when specified.

## Consequences

**Positive:**
- Transparent parallelism for I/O-bound LLM/tool calls with no dependency
  changes.
- Compatible with all Ruby versions in the support matrix (3.2, 3.3, 3.4, head).
- Simple to reason about: each task is an independent thread; results are
  collected in input order.

**Negative / Tradeoffs:**
- CPU-bound work inside agents does not benefit from true parallelism due to
  the GVL. (In practice, agents are almost always I/O-bound.)
- Spawning many threads simultaneously (no `max_concurrency:`) can exhaust
  system thread limits under high load. Users should set `max_concurrency:` for
  large fan-outs.
- Ractor-based isolation (if ever needed for security sandboxing) would require
  significant API changes to `WorkflowContext` and RubyLLM integration.
