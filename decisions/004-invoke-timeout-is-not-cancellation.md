# ADR-004: invoke_timeout Is a Wait Timeout, Not a Cancellation Signal

## Status

Accepted

## Context

`Agent::Base` exposes `invoke_timeout N` as a class-level DSL. When an invocation
exceeds the timeout, `Phronomy::TimeoutError` is raised to the caller.

The question is: should the timeout also stop the agent's background work?

Ruby's `Timeout.timeout` / `Thread#kill` can interrupt a running thread, but
doing so is unsafe: it can leave mutexes locked, database connections in a broken
state, and external API calls mid-flight without cleanup. `Thread#raise` has the
same hazards because it can interrupt anywhere inside a `rescue`/`ensure` block.

Cooperative cancellation (checking a shared flag periodically) is safe but
requires every tool, every LLM call, and every framework-internal loop to
participate — a significant API surface change.

## Decision

`invoke_timeout` is a **wait timeout only**. When the deadline is reached:

- `TimeoutError` is raised in the calling thread.
- The agent's background thread continues running until it either completes
  normally or is garbage-collected when the process ends.
- No cancellation signal is sent to the agent.

This is explicitly documented in the README and in the DSL source.

A proper cooperative cancellation mechanism is tracked in Issue #216
(`CancellationToken`), which is a separate feature requiring agent, tool, and
transport layer participation.

## Consequences

**Positive:**
- No risk of leaving shared resources (DB connections, mutexes, sockets) in a
  broken state due to forced thread interruption.
- Implementation is simple: `Timeout.timeout` on the calling side only.
- The contract is explicit and predictable.

**Negative / Tradeoffs:**
- Background threads may continue consuming resources (LLM API quota, etc.)
  after the caller has given up.
- Users who expect "cancel" semantics from a timeout will be surprised.
- Proper cancellation requires the `CancellationToken` feature (#216), which
  has not yet been implemented.
