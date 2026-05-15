# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.2.1] — Unreleased

### Changed

- **`WorkflowRunner` — state_machines fully drives execution** (architecture overhaul).
  Previously `state_machines` was used only for post-hoc transition validation;
  the next-node was calculated by Phronomy internally (`resolve_next_node`).
  As of 0.3.0, all state transition decisions — including guard evaluation for
  routing events — are delegated entirely to `state_machines`.
  - `PhaseTracker` now exposes `attr_accessor :context` so guard lambdas can
    access the `WorkflowContext` via `m.context`.
  - Guard bridge pattern: `if: ->(m) { guard_proc.call(m.context) }`.
  - Three event types registered per workflow:
    1. `advance_<from>` — unconditional after-transitions
    2. `<routing_event>` — guarded branching from action states (name is the
       event name used in the DSL, e.g. `:route`, `:route_review`)
    3. `<external_event>` — human-in-the-loop triggers from wait states
  - Invalid transitions now raise `ArgumentError` instead of logging warnings.
- **`WorkflowRunner` initializer signature changed** — `edges:`,
  `conditional_edges:`, and `wait_states:` replaced by `after_transitions:`,
  `route_transitions:`, `external_events:`, and `wait_state_names:`.
  This is an **internal-only** change; the public `Phronomy::Workflow.define` DSL
  is unchanged.

### Removed (internal)

- `WorkflowRunner#resolve_next_node` — logic moved to state_machines
- `WorkflowRunner#advance_phase` — replaced by `fire_event!`
- `Workflow::Builder#build_edges`, `#build_conditional_edges`,
  `#build_wait_states` — replaced by unified event classification in `build`

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
