# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **`Phronomy::Graph::Context`** module — canonical module for defining workflow
  context classes (replaces the removed `Phronomy::Graph::State`).
- **`Phronomy::Graph.register_context_class`** — registers context classes for
  deserialization from external stores (Redis, DB).
- **`Phronomy::Workflow.define`** DSL — primary high-level API for declaring
  stateful workflows (`state`, `wait_state`, `event`, `after`, `initial`).
- **`Phronomy::Graph::WorkflowRunner`** — state-machine execution engine backing
  the Workflow DSL. Replaces the removed `CompiledGraph`.
- **`app.send_event(event, config:)`** — event-driven resume for workflows halted
  at a `wait_state`.
- **`state.halted?`** — returns `true` when the workflow is paused at a `wait_state`.
- **`state.phase`** — single source of truth for execution state.

### Removed

- `Phronomy::Graph::StateGraph` / `CompiledGraph` — use `Phronomy::Workflow.define`.
- `Phronomy::Graph::State` — use `Phronomy::Graph::Context`.
- `Phronomy::Graph.register_state_class` — use `register_context_class`.
- `state.current_nodes` / `state.halted_before` — use `state.phase` / `state.halted?`.
- `compiled.interrupt_before` / `compiled.interrupt_after` — use `wait_state` + `event`.
- `compiled.resume` — use `app.send_event`.

---

## [0.2.0] - 2026-05-13

### Added

- `Phronomy::Graph::WorkflowRunner` — state_machines-based execution engine
  (introduced as the internal successor to `CompiledGraph`).
- `state.phase` — single source of truth for graph execution state (replaces
  `current_nodes` + `halted_before` dual attributes).
- `state.halted?` — returns `true` when the graph is paused.
- `CompiledGraph#add_wait_state` — declared a named wait state that halts
  automatically when reached (later superseded by `wait_state` DSL in `Workflow.define`).
- `CompiledGraph#send_event(state:, event:, input: nil)` — event-driven resume API
  (later superseded by `app.send_event`).

### Removed

- `ParallelNode` and `add_parallel_node` DSL. Use `Thread.new` or
  `Concurrent::Future` at the application level instead.
- `Phronomy::Graph::TimeoutError` (was only used by `ParallelNode`).
