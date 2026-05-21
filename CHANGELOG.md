# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- **`WorkflowContext` return value from entry actions is now adopted in EventLoop mode** ([#107]):
  `FSMSession` previously discarded the `WorkflowContext` returned by entry action callables,
  causing `s.merge(...)` updates to be silently lost when `event_loop = true`. The context is
  now correctly propagated, bringing EventLoop semantics in line with the synchronous
  `WorkflowRunner`. Regression tests added in `spec/phronomy/fsm_session_spec.rb` (unit)
  and `spec/integration/workflow_spec.rb` (integration, both sync and EventLoop paths).

---

## [0.6.0] - 2026-05-21

### Removed

- **`Phronomy::Guardrail::Builtin` module removed**: `PromptInjectionDetector`
  and `PIIPatternDetector` are opt-in pattern-matching helpers that encode
  application-level policy decisions (which phrases to block, which PII
  categories to detect, which languages to support). Shipping them as gem
  defaults was misleading — their correct home is inside each application that
  needs them. Reference implementations are now provided in example 06 of
  `phronomy-examples`. Extend `Phronomy::Guardrail::InputGuardrail` directly to
  create equivalent guardrails in your application.

---

## [0.5.4] - 2026-05-20

### New Features

- **VectorStore embedding dimension validation** (#98): All three vector store
  implementations (`InMemory`, `RedisSearch`, `Pgvector`) now validate that every
  embedding passed to `add` and `search` matches the expected dimension.
  Dimension is inferred automatically from the first `add` call; alternatively
  it can be set explicitly via `initialize(dimension: N)`. A mismatch raises
  `ArgumentError` with a descriptive message. The `search` method never
  establishes the dimension — it only validates when a dimension is already
  known. `clear` retains the established dimension (schema property).

- **`dispatch_parallel` / `fan_out` concurrency controls** (#99): Two new
  keyword arguments are now accepted by both methods.
  - `max_concurrency: nil` (default) or a positive `Integer` — caps the number
    of worker threads. `nil` means one thread per task (previous behaviour).
  - `on_error: :raise` (default) or `:skip` — controls failure handling.
    `:raise` runs all tasks to completion then re-raises the first error in
    input order (fail-last, not fail-fast). `:skip` fills failed slots with
    `nil` and never raises.
  The underlying implementation uses a `Queue`-based bounded worker pool
  (`bounded_map`) for predictable resource usage.

---

## [0.5.3] - 2026-05-20

### Bug Fixes

- **Ensure `from_server` closes transport on error** (#95): The short-lived
  transport created inside `McpTool.from_server` is now wrapped in
  `begin/ensure`, so the underlying child process (stdio) is always
  terminated even when `fetch_tool` raises.
- **Correct `McpTool#close` documentation** (#94): The comment previously
  stated that calling `execute` after `close` raises an error; in practice
  the transport reopens automatically. The comment now reflects actual
  behaviour.

### Documentation

- **Fix CHANGELOG date for v0.5.1** (#96): The v0.5.1 entry had an
  incorrect date of 2026-05-21; corrected to 2026-05-20.

---

## [0.5.2] - 2026-05-20

### Bug Fixes

- **CHANGELOG correction for v0.5.1 MCP fix** (#90): The v0.5.1 entry
  incorrectly stated that a `Mutex` was added to `StdioTransport#rpc_call`.
  The actual fix was per-instance transport ownership (each `McpTool` instance
  creates its own transport in `initialize`). Corrected the description.

### Enhancements

- **Add `McpTool#close`** (#92): Tool instances now expose a `close` method
  that shuts down the underlying stdio child process (`StdioTransport`) or
  releases the HTTP connection (`HttpTransport`). This gives callers a
  deterministic way to clean up resources instead of relying on GC.

### Maintenance

- **Archive stale Rails integration design doc** (#91): Added an archived
  notice to `spec/design/17_rails_integration.md` clarifying that Rails
  integration was removed in v0.3.0–v0.5.1 and the document is for
  historical reference only.

- **Remove zombie `register_workflow_context` API** (#93): The
  `Phronomy.register_workflow_context`, `workflow_context_registry`, and
  `reset_workflow_context_registry!` methods (along with the backing
  `@workflow_context_registry` and `@registry_mutex` module-level variables)
  were removed from `lib/phronomy.rb`. These existed to support the
  `StateStore` deserialization guard, which was removed in a prior release.
  The API had no remaining callers in the codebase and was not listed in
  the README stability table.

---

## [0.5.1] - 2026-05-20

### Bug Fixes

- **Remove broken Rails generator and Railtie** (#85): The generator template
  referenced `Phronomy::ActiveRecord::ActsAs` which no longer exists, causing
  `rails generate phronomy:install` to produce broken model files. Removed
  `lib/generators/`, `lib/phronomy/railtie.rb`, and all references in
  `lib/phronomy.rb`.

- **Fix MCP transport ownership** (#86): `McpTool` no longer stores a shared
  transport at class level. `from_server` now uses a short-lived transport only
  to fetch tool metadata and calls `close` immediately after. Each tool instance
  creates its own `StdioTransport` or `HttpTransport` in `initialize`, so
  concurrent callers (e.g. via `Orchestrator#dispatch_parallel`) never share
  stdio streams. No `Mutex` is needed. Also adds missing
  `require "securerandom"` and a no-op `HttpTransport#close` for interface
  consistency.

### Documentation

- **README corrections** (#87): Remove stale Rails generator installation
  instructions. Clarify that `TeamCoordinator` worker state is local to a
  single `invoke` call (not persistent across calls). Annotate app-level
  examples (`09_rails_chat`, `15_rails_secure_chat`, `18_rails_agent_job`,
  `19_trust_pipeline`) as requiring external infrastructure. Add scope note
  to `Agent::Orchestrator` section.

### Maintenance

- **Add version guard to `ruby_llm_patches.rb`** (#88): The monkey-patch for
  the upstream `handle_error_chunk` bug (ruby_llm <= 1.15.0) is now
  gated behind a `Gem::Version` check so upgrading ruby_llm will
  automatically disable the override.

---

## [0.5.0] - 2026-05-20

### Breaking Changes

- **`Agent::Base#invoke` and `#stream` — `messages` and `thread_id` promoted to
  top-level keyword arguments**:
  Previously these values were passed inside the `config:` hash. They are now
  explicit keyword arguments. The `config:` hash retains other runtime options
  such as `:knowledge_sources`, `:user_id`, and `:session_id`.

  **Before (v0.4.x)**:
  ```ruby
  agent.invoke(input, config: { messages: prior_msgs, thread_id: "t1" })
  agent.stream(input, config: { messages: prior_msgs, thread_id: "t1" }) { |e| ... }
  ```
  **After (v0.5.0)**:
  ```ruby
  agent.invoke(input, messages: prior_msgs, thread_id: "t1")
  agent.stream(input, messages: prior_msgs, thread_id: "t1") { |e| ... }
  ```
  Applications that only pass `:knowledge_sources`, `:user_id`, or `:session_id`
  in `config:` require no changes.

- **`Agent::Checkpoint#initialize` — `original_input:` is now a required keyword
  argument**: Applications that construct `Checkpoint` instances directly must
  add `original_input: input`. Checkpoints produced by `#invoke` already include
  this field automatically.

### Fixed

- **`ReactAgent#step` — system instructions were never applied**: The first
  iteration of the ReAct loop now calls `build_context` to assemble the system
  prompt and history, matching the behaviour of `Agent::Base`. Subsequent
  iterations re-apply instructions via `build_cached_system_text` before calling
  `chat.complete`. Previously, all iterations silently omitted the system prompt.

- **`Agent::Base#resume` — system instructions were not re-applied after
  suspension**: Resuming from a `Checkpoint` now calls `build_cached_system_text`
  using the original input stored in the checkpoint, so the LLM receives the
  correct system prompt when the conversation continues. Previously, the LLM was
  called without any system instructions on resume.

---

## [0.4.0] - 2026-05-19

### Removed

- **`Phronomy::TrustPipeline` removed**: The `TrustPipeline` class and its inner
  `TrustResult` value object have been deleted. Use `Phronomy::GeneratorVerifier`
  instead, which provides the same generator-verifier pattern with a cleaner,
  fully injectable API.

### Added

- **`Phronomy::GeneratorVerifier`** — Generator-Verifier coordination loop
  (Anthropic blog, Pattern 1). Wraps a generator agent and a verifier agent with
  fully injectable prompt builders, response parsers, a configurable iteration
  limit, and an approval-outcome raise policy.
- **`Phronomy::Agent::Orchestrator`** — Base class for orchestrator agents
  (Anthropic blog, Pattern 2). Extends `Agent::Base` with a `subagent` DSL for
  declarative subagent registration as LLM-callable tools, plus `dispatch_parallel`
  and `fan_out` for programmatic parallel invocation.
- **`Phronomy::Agent::TeamCoordinator`** — Agent teams coordination pattern
  (Anthropic blog, Pattern 3). An LLM-powered coordinator with a shared task
  queue and a pool of worker agents that carry conversation history across task
  assignments. Adds `coordinator_provider` DSL for independent LLM routing.
- **`Phronomy::Agent::SharedState`** — Shared-state coordination pattern
  (Anthropic blog, Pattern 5). Peer agents collaborate via a `KnowledgeStore`;
  the `member` DSL registers agents with per-agent instructions; `coordination`
  sets the team protocol; `build_prompt` injects a tool-usage guide automatically.
- **`Phronomy::LowConfidenceError`** — Exception raised by `GeneratorVerifier`
  when `raise_policy: :raise` and verification fails after exhausting the
  iteration limit.

### Changed

- **`Phronomy::Graph::StateGraph` event system refactored**: Per-node `advance`
  events replaced with a unified `node_completed` event queue, reducing
  event-handler registration overhead and simplifying listener registration.

---

## [0.3.0] - 2026-05-18

### Removed

- **`Phronomy::Memory` module fully removed**: `ConversationManager`, all
  `Storage` backends (InMemory, ActiveRecord), all `Retrieval` strategies
  (Recent, Semantic, Composite), and all `Compression` helpers (ToolOutputPruner,
  Summary) have been deleted. Conversation history is now the responsibility of
  the calling application — pass prior messages via `config[:messages]`
  (`Array<RubyLLM::Message>`) and receive the updated array in `result[:messages]`.
- **`Phronomy::StateStore` module fully removed**: `InMemory`, `ActiveRecord`,
  `Redis`, and `FileSystem` state-store backends have been deleted. The Workflow
  halted-state object is now returned directly from `invoke` and `send_event`
  and must be stored by the caller if resumption is needed.
- **`Phronomy::Configuration#default_state_store` removed**: No longer meaningful
  without a built-in state store.
- **`Phronomy::Configuration#default_memory` / `#memory_async` / `#memory_job_queue` removed**:
  No longer meaningful without the Memory module.
- **Rails integration removed**: `Railtie` initializers for `AgentJob` and
  `acts_as_phronomy_message` no longer load. The `rails/` and `active_record/`
  directories have been deleted.
- **`Phronomy::Actor` and `Phronomy::ThreadActorRegistry` deleted**: The Active
  Object pattern implementation (`actor.rb`, `thread_actor_registry.rb`) has been
  removed. It provided synchronous blocking only (no true async) and was
  architecturally inconsistent with the `WorkflowRunner` halt/resume model. All
  thread coordination now uses plain `Mutex` where needed.
- **`Phronomy.configuration.max_actors` removed**: The configuration option is no
  longer meaningful without `ThreadActorRegistry`.

### Changed

- **`Agent::Base#invoke` and `#stream`** no longer route execution through a
  per-thread Actor. Both methods now call `_invoke_impl` / `_stream_impl` directly
  on the calling thread.
- **`Memory::Storage::InMemory`** now stores all thread data in an instance-level
  `Hash` instead of `Thread.current` thread-local storage. The class-level
  `THREAD_DATA_KEY` constant has been removed. `with_thread_lock` uses a
  per-thread-id `Mutex` to preserve concurrent-compaction safety (issue #44).
- **`StateStore::InMemory`** now stores state in an instance-level `Hash`.
  The `THREAD_DATA_KEY` constant has been removed.
- **`VectorStore::RedisSearch`** uses a `Mutex` for `ensure_index!` and `clear`
  instead of an Actor, preserving the thread-safety invariant on `@index_created`.
- **`Tool::McpTool::StdioTransport`**, **`Tracing::LangfuseTracer`**,
  **`TrustPipeline`**, and **`Memory::Retrieval::Semantic`** no longer hold a
  dedicated Actor instance. All operations execute directly on the calling thread.
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

- **`RubyLLM::Providers::OpenAI#handle_error_chunk` — `NoMethodError` on single-line SSE error chunks**:
  Some models (e.g. Qwen running via LM Studio) return SSE error events as a
  single line (`data: {...}`) without a preceding `event:` line. The upstream
  implementation called `chunk.split("\n")[1].delete_prefix(...)`, which raised
  `NoMethodError: undefined method 'delete_prefix' for nil` when the second
  element was absent. A monkey-patch in `lib/phronomy/ruby_llm_patches.rb` guards
  against this by returning an empty string when the split result has fewer than
  two elements.
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
