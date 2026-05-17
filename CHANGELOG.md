# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Changed

- **`PIIPatternDetector` — `:my_number` replaced by `:ssn`** ([#77]): The built-in PII
  detector now checks for US Social Security Numbers (`\b\d{3}-\d{2}-\d{4}\b`) instead
  of Japanese My Numbers. The JIS X 0076 check-digit validation and `my_number_valid?`
  helper have been removed. Category key renamed from `:my_number` to `:ssn`.
- **`PIIPatternDetector` — phone pattern updated to international format** ([#77]):
  The `:phone` pattern now matches 3-digit area code + 3–4-digit exchange + 4-digit
  subscriber number with optional E.164 country-code prefix
  (`(?:\+\d{1,3}[.\- ]?)?\(?\d{3}\)?[.\- ]?\d{3,4}[.\- ]?\d{4}\b`),
  replacing the previous Japan-specific pattern.

### Fixed

- **`README` — stale Memory API examples** ([#76]): All references to the
  non-existent `WindowMemory`, `ActiveRecordMemory`, `SemanticMemory` classes and
  `load_messages` / `memory_compression` API have been replaced with the correct
  `ConversationManager`-based API.
- **`README` — `PIIPatternDetector` comment** ([#77]): Inline comment updated to
  `# Detect SSNs, credit cards, emails, and phone numbers`.
- **`README` — Configuration block markdown** ([#80]): The `max_actors` Note block
  was incorrectly placed inside the Ruby code fence; moved outside so it renders
  as a blockquote.
- **`README` — `Guardrails` stability label** ([#76]): Changed from `Stable` to `Beta`
  to reflect that the built-in detector patterns may evolve.
- **`CHANGELOG` — stale entries** ([#78]): Removed the orphaned `[Unreleased]` section
  describing a never-released API, and replaced a forward `"As of 0.3.0"` reference
  with future-tense wording.
- **`McpTool` — YARD class comment** ([#79]): Updated to document both the
  `stdio://` and `http://`/`https://` transport schemes.
- **`README` — `max_actors` configuration reference** ([#80]): Added `c.max_actors`
  example and LRU eviction note to the Configuration section.

---

## [0.2.2] - 2026-05-17

### Fixed

- **`Tool::Base` type validation — strict mode** ([#73]): Removed string-coercion
  pass-through for `:integer`, `:number`/`:float`, and `:boolean` parameters.
  A `String` value such as `"42"` now correctly raises a type error regardless
  of the `on_schema_error` mode. Fixes silent data corruption where the raw
  string was forwarded to `execute` instead of the expected numeric/boolean type.
- **`README` — correct `send_event` API example** ([#69]): Fixed code sample that
  called `app.send_event(:approve, config: { thread_id: ... })` (positional args)
  which raises `ArgumentError` at runtime. Corrected to
  `app.send_event(state: state, event: :approve)`.
- **`phronomy.gemspec` — exclude `vendor/` from gem package** ([#70]): `vendor/bundle`
  (~3 500 files, ~14 MB) was included in released gems. Added `"vendor/"` to the
  file reject list.

### Added

- **`Phronomy::Configuration#max_actors`** ([#72]): New optional attribute
  (default `nil` = unlimited, backward-compatible). When set, `ThreadActorRegistry`
  enforces an LRU eviction policy: the least-recently-used actor is stopped and
  removed before a new one is created, preventing unbounded thread growth in
  long-running processes.
- **`README` — feature stability table** ([#71]): Features section now uses a
  table with Stable / Beta / Experimental labels so users can assess maturity at
  a glance.
- **`TrustPipeline::Result#citations` — unverified-source warning** ([#74]):
  YARD documentation now explicitly states that citations are extracted from the
  LLM's own output and have not been verified against any external source.

### CI

- **Ruby 3.4 added to CI matrix** ([#75]): Aligns test coverage with the gemspec
  requirement (`>= 3.2.0`) and verifies compatibility with the current stable
  Ruby release.

[#69]: https://github.com/Raizo-TCS/phronomy/issues/69
[#70]: https://github.com/Raizo-TCS/phronomy/issues/70
[#71]: https://github.com/Raizo-TCS/phronomy/issues/71
[#72]: https://github.com/Raizo-TCS/phronomy/issues/72
[#73]: https://github.com/Raizo-TCS/phronomy/issues/73
[#74]: https://github.com/Raizo-TCS/phronomy/issues/74
[#75]: https://github.com/Raizo-TCS/phronomy/issues/75

---

## [0.2.1] — Unreleased

### Changed

- **`WorkflowRunner` — state_machines fully drives execution** (architecture overhaul).
  Previously `state_machines` was used only for post-hoc transition validation;
  the next-node was calculated by Phronomy internally (`resolve_next_node`).
  After this change, all state transition decisions — including guard evaluation for
  routing events — will be delegated entirely to `state_machines`.
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
