# ADR 009: StateStore Abstraction for Workflow Persistence

**Status**: Superseded by ADR-014  
**Date**: 2025-01  
**Issue**: [#250](https://github.com/Raizo-TCS/phronomy/issues/250)

---

## Context

`Phronomy::WorkflowContext` stores execution state in a plain Ruby object that lives only
in the process heap for the duration of a single `invoke` call. This is intentional for
simple, stateless pipelines but creates three gaps:

1. **Process restart** destroys all in-flight workflow state. Long-running workflows (approval
   pipelines, human-in-the-loop, async batch jobs) cannot survive a deploy or crash.
2. **Multi-process fan-out** is impossible when all state is local. Horizontally-scaled
   workers cannot hand off an in-progress workflow to a sibling process.
3. **Debugging & auditability** — there is no canonical, queryable record of what a workflow
   produced at each turn.

The only persistence mechanism that existed before this ADR was the caller manually
persisting the `WorkflowContext` object returned by `invoke` and passing it back to
`send_event`. This is fragile and couples the caller to Phronomy internals.

---

## Decision

Introduce a `StateStore` abstraction — a single, narrow interface that `WorkflowRunner`
uses for all state reads and writes. Callers opt in by passing a `state_store:` argument
to `Workflow.define` or by setting `Phronomy.configure { |c| c.state_store = … }`.

### Interface

```ruby
# lib/phronomy/state_store/base.rb
module Phronomy
  module StateStore
    class Base
      def load(thread_id)          = raise NotImplementedError  # → Hash | nil
      def save(thread_id, snapshot) = raise NotImplementedError  # → void
      def delete(thread_id)        = raise NotImplementedError  # → void
    end
  end
end
```

A **snapshot** is a plain `Hash` with two keys:

| Key | Type | Description |
|-----|------|-------------|
| `:fields` | `Hash` | Output of `context.to_h` — user-defined field values |
| `:phase`  | `String` | `context.phase.to_s` — last recorded execution phase |

### Built-in backends

| Class | Dependency | Use case |
|-------|-----------|---------|
| `StateStore::InMemory` | none | Testing, single-process, default |
| `StateStore::SQLite` | `sqlite3` gem | Simple production durability (not in scope) |
| `StateStore::Redis` | `redis` gem | Multi-process, TTL support (not in scope) |

This ADR covers only the interface contract and `InMemory`. SQLite and Redis backends
are deferred to separate issues.

### Integration with WorkflowRunner

`WorkflowRunner` resolves the store in the following priority order:

1. `config[:state_store]` passed per-invocation
2. `state_store:` kwarg passed to `WorkflowRunner#initialize`
3. `Phronomy.configuration.state_store`
4. `nil` → no persistence (current default behaviour)

On each `invoke` call that provides an explicit `thread_id`:

```
invoke(input, config: { thread_id: "t1" })
  → load snapshot for "t1" (if store present)
  → merge stored fields with input (input overrides stored values)
  → run workflow from entry_point
  → save final context snapshot for "t1"
```

On subsequent calls with the same `thread_id`, the stored fields are loaded as the
initial context. The `phase` field in the snapshot is recorded but `invoke` always
restarts from the entry point — the stored phase is informational. To resume a halted
workflow at a specific named event, callers use `send_event`.

---

## Consequences

### Positive

- Pluggable backends: tests use `InMemory`; production uses `SQLite` or `Redis`.
- Zero-change opt-out: when no store is configured, `WorkflowRunner` behaviour is
  identical to the pre-ADR implementation (no reads, no writes).
- `InMemory` replaces the implicit in-memory hash that previously lived only for the
  duration of a single call: callers can now persist state across multiple `invoke`
  calls in the same process without glue code.
- Shared RSpec examples (`"a state store"`) enforce the contract for all backends.

### Negative / Trade-offs

- Snapshot serialization is the caller's responsibility for complex field types. Fields
  that contain non-JSON-safe objects (e.g. `Proc`, `Symbol` keys) must serialize cleanly
  via `to_h`. `InMemory` stores Ruby objects directly (no serialisation), so it does
  not expose this issue during tests.
- `invoke` always re-runs the workflow from the entry point — loading stored state does
  NOT automatically resume a halted wait_state. Callers who want resume-from-halt
  semantics must call `send_event` explicitly (as before).
- The `:phase` field in the snapshot is currently informational (not used by `invoke`
  to auto-resume). A future ADR may introduce auto-resume semantics.

---

## Alternatives Considered

### A. Make InMemory the global default

Set `Phronomy.configure { c.state_store = InMemory.new }` automatically on boot.
Rejected: this would change the memory lifecycle of all workflows silently; existing
tests relying on ephemeral state would accumulate in the default store indefinitely,
and the store would become a slow memory leak in long-running processes.

### B. Serialize snapshots to JSON at the InMemory layer

Round-trip through JSON in `InMemory#save` to catch serialisation issues early.
Rejected for this ADR: `InMemory` is intended as a zero-friction default for tests and
local development. JSON round-tripping would penalise symbol keys (a common pattern in
Ruby apps). The SQLite/Redis backends will enforce JSON round-tripping at their layer.

### C. Auto-resume halted workflows in `invoke`

When `invoke` finds a stored snapshot with `phase != "__end__"`, automatically call
`send_event` with a synthetic `:resume` event.
Rejected: the correct event to fire depends on the wait_state's declared external events,
which may require named events (e.g. `:approve`, `:reject`). Inferring the right event
automatically is ambiguous and would hide programmer errors.
