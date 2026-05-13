# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **`Phronomy::Graph::Context`** module — the canonical module for defining graph
  context classes. Replaces `Phronomy::Graph::State` as the primary name.
  `State` remains as a backward-compatible constant alias and will be removed in v1.0.
  **Existing code does not need to change.**
- **`Phronomy::Graph.register_context_class`** — registers context classes for
  deserialization from external stores (Redis, DB). `register_state_class` is
  kept as a deprecated alias.
- **`interrupt_before` (no-block form)** — calling `compiled.interrupt_before(:node)`
  without a block now always halts before the node (equivalent to passing `{ :halt }`).
- **`send_event(state:, event: :resume)`** — the generic `:resume` event now works
  for all halt types: `interrupt_before`, `interrupt_after`, and `add_wait_state`.
  No need to know which halt mechanism was used when resuming.
- **`resume`** is now a thin wrapper around `send_event(event: :resume)`.
  The method signature and behavior are unchanged.

### Changed

- Internal `WorkflowRunner` now uses the `state_machines` gem for phase
  tracking. Public API is unchanged.
- `Phronomy::Graph::State` is now a constant alias (`State = Context`).
  The implementation lives in `context.rb`.

### Deprecated

- `Phronomy::Graph::State` — use `Phronomy::Graph::Context` in new code.
  Will be removed in v1.0.
- `Phronomy::Graph.register_state_class` — use `register_context_class`.
  Will be removed in v1.0.
- `state.current_nodes` / `state.halted_before` — use `state.phase` and
  `state.halted?`. Will be removed in v1.0.
- `compiled.resume(state:, input:)` — use `compiled.send_event(state:, event: :resume)`.
  Will be removed in v1.0.

---

## [0.2.0] - 2026-05-13

### Added

- `Phronomy::Graph::WorkflowRunner` — state_machines-based execution engine
  that powers `CompiledGraph` internally.
- `state.phase` — single source of truth for graph execution state (replaces
  `current_nodes` + `halted_before` dual attributes).
- `state.halted?` — returns `true` when the graph is paused.
- `CompiledGraph#add_wait_state` — declares a named wait state that halts
  automatically when reached.
- `CompiledGraph#send_event(state:, event:, input: nil)` — event-driven resume API.

### Removed

- `ParallelNode` and `add_parallel_node` DSL. Use `Thread.new` or
  `Concurrent::Future` at the application level instead.
- `Phronomy::Graph::TimeoutError` (was only used by `ParallelNode`).
