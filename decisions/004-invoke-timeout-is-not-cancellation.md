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

## Extension: PendingOperation#await cooperative cancellation semantics

`BlockingAdapterPool::PendingOperation#await` also supports both `timeout:` and
`cancellation_token:` parameters. The same non-preemptive rule applies here,
consistent with ADR-010 (cooperative-first, non-preemptive concurrency model):

1. **No forcible thread termination.** When a `cancellation_token` is cancelled
   or the timeout fires, `CancellationError` is raised to the `await` caller,
   but the underlying worker thread is **not** killed. The worker runs its block
   to natural completion.
2. **Cooperative, not preemptive.** Cancellation takes effect only at `await`
   call sites or at explicit `token.check!` checkpoints inside the submitted
   block. Code that ignores the token will not be interrupted.
3. **Timeout scope.** `timeout:` at `await` time is measured from the moment
   `await` is called. If both submit-time and await-time timeouts are provided,
   the earlier deadline wins.
4. **Error propagation.** `CancellationError` (or `TimeoutError`) is raised to
   the `await` caller; the submitter is responsible for handling it.

These semantics are identical in spirit to the `invoke_timeout` decision above:
the framework exposes a *wait* boundary, not a hard-kill boundary. Safe resource
cleanup is the caller's responsibility.

