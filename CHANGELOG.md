# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- **`llm_timeout` / `tool_timeout` now fire on the `on_complete` path**:
  `BlockingAdapterPool#submit` previously stored the timeout value but never
  registered a wall-clock timer, so `config: { llm_timeout: N }` and
  `config: { tool_timeout: N }` had no effect for callers using `on_complete`
  (the normal non-streaming Agent path). The timer is now armed before queue
  admission and calls `fire_timeout!` when the deadline expires.

### Changed

- **`blocking_wait(timeout:)` is now a waiter-local deadline only**:
  Previously, the timeout passed to `blocking_wait` (or `wait_result`) would settle the
  operation, set `abandoned? = true`, and increment `abandoned_count` — affecting
  all future waiters and callbacks. It is now scoped to the single calling thread:
  the caller receives `TimeoutError`, but the operation remains unsettled. Other
  waiters or `on_complete` callbacks will still receive the eventual result unless
  a separate submit-time deadline or cancellation settles the operation first.
  **Callers that relied on `blocking_wait(timeout:)` to abandon and count an
  operation must switch to a submit-time `timeout:` passed to `pool.submit`.**

- **Queue-timeout operations are not counted as abandoned**:
  When a submit-time timeout fires before the worker picks up the operation,
  the operation is settled with `TimeoutError` but `abandoned? == false` and
  `abandoned_count` is not incremented. Only timeouts that fire while the block
  is executing set `abandoned? = true`.

- **MCP client support now requires `mcp` 1.x**:
  The `mcp` SDK 0.x dependency is no longer supported. The constraint is now
  `mcp ~> 1.0`. `faraday` and `event_stream_parser` are added as direct runtime
  dependencies so HTTP/SSE transport works without relying on transitive
  resolution through RubyLLM.

- **MCP Tool error handling follows MCP 1.x semantics**:
  JSON-RPC errors (`MCP::Client::ServerError`) are converted to
  `Phronomy::ToolError`. Cancellations (`MCP::CancelledError`) are converted to
  `Phronomy::CancellationError`. Tool-level `isError: true` results are
  returned to the model as error text rather than raising, allowing the LLM to
  self-correct.

- **MCP input schemas now use a strict supported subset of JSON Schema 2020-12**:
  Unsupported structural keywords (`oneOf`, `anyOf`, `allOf`, `$ref`, etc.),
  nested object/array types, and nullable type arrays fail fast with
  `Phronomy::ToolError` at `from_server` time. Constraint-only annotations
  (`minimum`, `maxLength`, `format`, etc.) produce a logger warning and are
  otherwise ignored. See [`docs/mcp-client.md`](docs/mcp-client.md) for the
  full supported schema subset.

- **MCP client cancellation now invalidates the transport**:
  After a `MCP::CancelledError` the internal client reference is set to `nil`
  and the old transport is closed asynchronously. The next tool call creates a
  fresh connection, preventing stdio response mis-routing from a lingering SDK
  worker thread.

---

## [0.13.0] - 2026-07-23

### Added

- **`Phronomy::Filter::Base` — unified value filter interface** (#389):
  A single abstract base class `Filter::Base` with one method `call(value, **context)`
  covers all three agent boundaries — user input, LLM output, and tool return values.
  Subclasses return the (possibly transformed) value to continue, or call `block!` /
  `raise Phronomy::FilterBlockError` to reject.  The same filter instance can be
  registered at multiple sites.  Guardrails registered via `add_input_guardrail` /
  `add_output_guardrail` are automatically included at the front of the filter chain.

  ```ruby
  class PiiMaskFilter < Phronomy::Filter::Base
    def call(value, **_context)
      value.to_s.gsub(/\b\d{2,4}-\d{2,4}-\d{4}\b/, "[PHONE]")
    end
  end

  f = PiiMaskFilter.new
  agent.add_input_filter(f)
  agent.add_output_filter(f)
  agent.add_tool_result_filter(CustomerDataTool, f)
  ```

  Class-level DSL counterparts: `input_filter`, `output_filter`, `tool_result_filter`.
  The `tools(Hash)` DSL also accepts a `:result_filter` key for per-tool scoping.

- **`Guardrail::Base#call` — Filter::Base-compatible interface**:
  `Guardrail::Base` now implements `call(value, **_context)`, which calls `check(value)`
  and returns the value unchanged (or raises `GuardrailError`).  Existing guardrail
  subclasses require no changes.

### Changed

- **Guardrail execution unified into the filter chain**:
  Guardrails registered via `add_input_guardrail` / `add_output_guardrail` now run
  as the first entries in `run_input_filters!` / `run_output_filters!`.  The separate
  `run_input_guardrails!` / `run_output_guardrails!` call sites in `invoke_once`,
  `_stream_impl`, and `Suspendable#resume` have been removed.  Behaviour is unchanged
  — guardrails still run before any filters and `GuardrailError` still propagates.

### Changed

- **MCP transport replaced by official `mcp` gem** (closes #280, #365):
  The hand-rolled `StdioTransport` and `HttpTransport` (~260 lines) have been
  replaced by `MCP::Client::Stdio` and `MCP::Client::HTTP` from the official
  `mcp` gem (v0.25.0+). Adds the `mcp >= 0.3` runtime dependency.
  - Built-in 4 MiB size limits for stdout, stderr, and HTTP responses
  - Automatic MCP `initialize` handshake on every connection
  - SSE response parsing handled by the SDK
  - `from_server` and `execute` convert SDK errors into `Phronomy::ToolError`
  - Removes all `Thread.new` usage from `mcp.rb`; entry removed from
    `THREAD_NEW_ALLOWLIST` in `thread_invariants_spec.rb`

- **`CancellationToken` bridged into MCP `call_tool`** (Issue #390):
  `Mcp#execute` now accepts a `cancellation_token:` keyword argument.
  When provided, the token is bridged to `MCP::Cancellation` via `on_cancel`,
  so an explicit `cancel!` propagates into the in-flight `call_tool` request
  as a MCP `notifications/cancelled` message.

- **`config[:tool_timeout]` forwarded to `BlockingAdapterPool`** (Issue #390):
  `ToolExecutor.call_async` and `Capability::Base#call_async` now accept a
  `config:` keyword. `config[:tool_timeout]` is passed as the `timeout:` to
  `pool.submit`, enabling the same abandoned-operation tracking that LLM calls
  already use via `config[:llm_timeout]`.



## [0.10.0] - 2026-06-08

### Added

- **`Task#map` — transform a Task's completed value** (#384):
  `task.map { |result| ctx.merge(answer: result[:output]) }` returns a new `Task`
  whose completed value is the block's return value. Primary use-case: wire
  `Agent::Base#invoke_async` into a Workflow entry action so the agent result
  reaches `WorkflowContext` through the standard `:action_completed` path without
  requiring any changes to `FSMSession`. If the source task fails or is cancelled,
  the mapped task propagates the error without calling the block.

### Removed

- **`Agent::Base#run_as_child` removed** (#384):
  Introduced when agents had their own FSM (`Agent::FSM`). After `Agent::FSM` was
  removed in v0.9.0, the `:child_completed` event payload was silently discarded by
  `FSMSession`, so `ctx.answer` was never populated. Migrate to
  `invoke_async + Task#map`:

  ```ruby
  # Before (removed)
  entry :translate, ->(ctx) { TranslationAgent.new.run_as_child(ctx.query, ctx: ctx) }
  transition from: :translate, on: :child_completed, to: :done

  # After (recommended)
  entry :translate, ->(ctx) {
    TranslationAgent.new.invoke_async(ctx.query).map { |r| ctx.merge(answer: r[:output]) }
  }
  transition from: :translate, to: :done
  ```

### Added

- **`Task#map` — transform a Task's completed value** (post-v0.9.0):
  `task.map { |result| ctx.merge(answer: result[:output]) }` returns a new `Task`
  whose completed value is the block's return value.  The primary use-case is
  connecting `Agent::Base#invoke_async` to a Workflow entry action so the agent
  result populates the `WorkflowContext` through the standard `:action_completed`
  path.  If the source task fails or is cancelled, the mapped task propagates the
  error without calling the block.

- **`Phronomy::Diagnostics` and `SchedulerReentrancyError`** (#278, #279):
  `Phronomy::Diagnostics` exposes a snapshot of current scheduler state
  (`pending_count`, `active_tasks`, `pool_utilization`, etc.) for debugging and
  monitoring. `SchedulerReentrancyError` is raised when a scheduler operation is
  attempted from within a scheduler callback, preventing deadlocks.
  `Phronomy.configure { |c| c.scheduler_debug = true }` enables verbose scheduler
  logging.

- **`task_id` / `parent_task_id` on `InvocationContext`** (#277):
  Every task spawned via `Task.spawn` now carries a `task_id` (a random UUID) and
  an optional `parent_task_id`. These fields enable hierarchical task-tree tracing
  and are forwarded automatically by `TaskGroup`.

- **`Phronomy::Metrics` — task-centric observability snapshot** (#276):
  `Phronomy::Metrics.snapshot` returns a hash with scheduler statistics:
  `tasks_started`, `tasks_completed`, `tasks_failed`, `pool_queue_depth`, and
  `pool_active_threads`. Intended for metrics export and health-check endpoints.

- **`Phronomy::Testing::FakeClock` and `FakeScheduler`** (#273):
  Two test helpers for deterministic concurrency testing.
  `FakeClock` exposes `advance(seconds)` to control the passage of time without
  sleeping. `FakeScheduler` replaces the real scheduler in specs, providing
  synchronous execution and `flush` / `drain` helpers to drive task completion.

- **`ScopePolicy` and approval gate integration** (#270):
  `Phronomy::Tool::ScopePolicy` is a callable that maps `(tool_class, scope, agent)`
  to `:allow`, `:approve`, or `:reject`. The default policy (`ScopePolicy::DEFAULT`)
  automatically routes tools declaring high-risk scopes (`:write`, `:admin`,
  `:external_network`, `:filesystem`, `:process`, `:external_process`) through the
  existing approval gate; tools with `scope :read_only` or no scope are allowed
  unconditionally. Per-agent policy overrides are available via
  `agent.scope_policy = my_policy`.
  **Behaviour change**: tools with the above scopes that previously executed without
  an approval handler will now be **rejected** unless an approval handler is
  registered or the agent uses a custom permissive policy.

- **`PromptInjectionGuardrail`, `Tool::Base#redact_params`, and `#max_result_size`** (#271):
  `Phronomy::Guardrail::PromptInjectionGuardrail` is a built-in `InputGuardrail`
  subclass that detects prompt-injection patterns in user input.
  `Tool::Base.redact_params(*names)` marks parameter names as sensitive; their
  values are replaced with `"[REDACTED]"` in log and trace output.
  `Tool::Base.max_result_size(n)` sets a per-tool character limit; results
  exceeding the limit are truncated and a warning is logged. The global fallback is
  `Phronomy.configure { |c| c.tool_result_max_size = n }` (default: no limit).

- **`execution_mode` DSL on `Tool::Base`** (#263):
  `Tool::Base.execution_mode` accepts `:cooperative`, `:blocking_io` (default),
  `:cpu_bound`, or `:external_process`. Tools marked `:blocking_io` (the default)
  are dispatched through `BlockingAdapterPool` when a `Runtime` is available,
  keeping the scheduler thread unblocked. Tools marked `:cooperative` are called
  directly on the scheduler thread (suitable for pure in-memory operations).

- **`invoke_async` and `call_async` — async entry points** (#262):
  `Agent::Base#invoke_async(input, **opts)` returns a `Phronomy::Task` wrapping
  `#invoke`. `Workflow#invoke_async(input, config:)` does the same for workflows.
  `Tool::Base#call_async(args, cancellation_token:)` returns a `Task` wrapping
  `#call`. All three are backward-compatible with existing synchronous callers.

- **`LLMAdapter` abstraction** (#266):
  `Phronomy::LLMAdapter::Base` decouples the agent pipeline from RubyLLM.
  `Phronomy::LLMAdapter::RubyLLM` (registered by default) wraps the existing
  integration. Custom adapters can be registered via
  `Phronomy.configure { |c| c.llm_adapter = MyAdapter }` for testing or
  alternative LLM backends.

- **`BlockingAdapterPool` backpressure limits** (#268):
  `BlockingAdapterPool` now enforces configurable `pool_size` (default: 10) and
  `queue_size` (default: 100) limits. Tasks submitted when the queue is full raise
  `Phronomy::BackpressureError` immediately instead of growing the queue without
  bound.

- **Cooperative scheduler fairness** (#269):
  The scheduler measures per-task lag and emits starvation and dispatch warnings
  via `Phronomy.configuration.logger` when tasks wait longer than configured
  thresholds. Configurable via `scheduler_starvation_warn_ms` and
  `scheduler_dispatch_warn_ms`.

- **Workflow entry actions awaitable with Task** (#264):
  Entry action lambdas may now return a `Phronomy::Task`. The FSMSession awaits
  the task on a background thread and posts `:action_completed` (with the resulting
  `WorkflowContext`) or `:state_completed` back to the EventLoop without blocking
  it. Backward-compatible: lambdas that return a `WorkflowContext` or `nil`
  continue to work as before.

- **`Task`, `TaskGroup`, `AsyncQueue`, `Deadline`, `InvocationContext`, `Runtime` concurrency abstractions** (#255):
  Six new concurrency primitives form the foundation of the async execution layer.
  `Task` wraps a callable with cancellation, timeout (`Deadline`), and context
  propagation (`InvocationContext`). `TaskGroup` runs tasks concurrently and waits
  for all to finish (or the first failure). `AsyncQueue` is a bounded, cancellable
  queue. `Runtime` is the top-level façade that resolves a `BlockingAdapterPool`
  and provides `blocking_io { }` and `cpu_bound { }` dispatch helpers.

- **`BlockingAdapterPool`** (#256):
  A bounded thread pool that isolates blocking I/O (LLM calls, database queries,
  HTTP requests) from the cooperative scheduler thread. Default pool size is 10
  threads with a queue depth of 100. Replaces direct `Thread.new` calls in core
  agent and tool paths.

- **`VectorStore#size` — document count for all backends, contract coverage for RedisSearch and Pgvector** (#240):
  `VectorStore::Base` gains `#size` as an abstract method; `InMemory`, `RedisSearch`,
  and `Pgvector` all implement it. `RedisSearch#size` queries `FT.INFO num_docs`;
  `Pgvector#size` delegates to `model_class.count`. The `a_vector_store` shared example
  is applied to RedisSearch and Pgvector (nightly real-backend CI); unit specs add a
  skip-guarded `it_behaves_like` reference and dedicated `#size` unit tests.
  `empty_store` override hook added to the shared example for real-backend callers.

- **`force_kill: false` default in `dispatch_parallel`, `fan_out`, and `EventLoop#stop`** (#235):
  Thread#kill is now opt-in. The default `force_kill: false` leaves timed-out workers
  running and raises `TimeoutError` immediately, avoiding the risk of interrupted
  `ensure` blocks or corrupted database transactions. Pass `force_kill: true` to
  restore the previous behaviour (with a `logger.warn` to make it visible).
  `EventLoop#stop` gains the same keyword and returns `:timeout` instead of
  `:force_killed` when `force_kill: false` and the thread is still alive.

- **Public API compatibility snapshot spec** (#236):
  `spec/phronomy/public_api_spec.rb` enumerates expected public methods for every
  `Stable`-tagged constant. The spec runs as part of the default RSpec suite; any
  accidental removal or rename of a listed method now fails CI immediately.

- **Nightly real-backend CI split into three independent job groups** (#238):
  The nightly workflow (`nightly.yml`) now has three separately skippable jobs:
  `real-backend-redis` (Redis Stack), `real-backend-pgvector` (PostgreSQL + pgvector),
  and `real-backend-otel` (OpenTelemetry in-process SDK exporter). Each job runs only
  the relevant spec with `--tag real_backend:<backend>`. The existing `redis_search_spec`
  and `pgvector_spec` gain the `real_backend:` metadata tag. A new `otel_spec.rb`
  verifies span emission, attribute attachment, and error recording via
  `InMemorySpanExporter`.

- **`CancellationToken#raise_if_cancelled!` — convenience cancellation check** (#234):
  New instance method that raises `Phronomy::CancellationError` when the token is
  cancelled, or returns `nil` otherwise. Replaces the `if cancelled? then raise`
  pattern inside tools, RAG loaders, and hooks.

- **Tool cooperative cancellation via `cancellation_token:` keyword** (#234):
  `Tool::Base#call` now injects `Thread.current[:phronomy_cancellation_token]` as
  `cancellation_token:` into `execute` when the method declares that keyword. Existing
  tools without the keyword continue to work unchanged. Tool authors can opt in:
  `def execute(query:, cancellation_token: nil)`.

- **`CancellationToken.timeout_after` — monotonic-clock deadline** (#225):
  New `CancellationToken.timeout_after(seconds)` class method creates a token that
  becomes cancelled after the specified number of seconds, measured with
  `Process::CLOCK_MONOTONIC` (immune to NTP/DST drift). The existing `deadline:`
  keyword for wall-clock deadlines remains supported for backward compatibility.

- **`EventLoop#stop` — drain mode and cooperative shutdown** (#233):
  `EventLoop#stop` now accepts a `drain: true` keyword (default: `false`). When
  set, the loop waits up to `Phronomy.configuration.event_loop_stop_grace_seconds`
  (default: 5 s, configurable) for in-flight FSM sessions to complete before
  joining threads. New sessions submitted while shutdown is pending are rejected
  immediately with `Phronomy::CancellationError`. A new
  `event_loop_stop_grace_seconds` configuration attribute is available on
  `Phronomy::Configuration`.

- **`invoke_timeout` DSL and `Phronomy::TimeoutError`**: Agents can declare a per-invoke
  timeout in seconds via `invoke_timeout N` in the class body. Exceeding the timeout raises
  `Phronomy::TimeoutError` (a subclass of `Phronomy::Error`). The default remains unlimited.

- **`dispatch_parallel` / `fan_out` — per-call `timeout:` option** (#133): Both methods now
  accept `timeout: nil` (default, unlimited) or a positive `Numeric` in seconds. Timed-out
  tasks are treated the same as errors and follow the existing `on_error:` policy (`:raise`
  or `:skip`).

- **MCP `HttpTransport` custom authentication headers** (#144): `Phronomy::Tools::Mcp::HttpTransport#initialize`
  now accepts `headers: {}`. Arbitrary headers (e.g. `Authorization: Bearer …`) are injected
  into every JSON-RPC request, enabling use of MCP servers that require bearer tokens or
  API keys. Threading `headers:` through `Mcp.from_server` is tracked in issue #144 and
  pending in PR #151.

- **`StdioTransport` — `env:`, `cwd:`, and `startup_timeout:` options** (#145):
  Three new keyword arguments are now accepted when constructing a `StdioTransport` (and
  therefore via `McpTool.from_server`): `env: {}` merges extra variables into the child
  process environment; `cwd: nil` sets the working directory; `startup_timeout: 5` limits
  how long to wait for the child process to become ready.

- **Workflow DSL validates graph structure at build time** (#124): `Phronomy::Workflow.define`
  now raises `ArgumentError` immediately for hard structural errors (no states declared,
  transitions referencing undefined targets). Unreachable states emit a warning but do not
  raise. Errors surface at load time rather than at the first `invoke`.

- **Expanded error taxonomy** (#149): Five new subclasses of `Phronomy::Error` are now
  available: `TransportError` (MCP or LLM network-layer failure; subclasses are
  `RateLimitError` for HTTP 429 and `AuthenticationError` for HTTP 401/403),
  `ContextLengthError` (prompt exceeds model context window), and
  `CancellationError` (explicit invocation cancellation, distinct from the
  deadline-exceeded `TimeoutError`). All five are defined as subclasses of
  `Phronomy::Error` so application code can rescue them uniformly.

- **`Agent::Base.static_knowledge_refresh!`** (#164): New class-level method that clears the
  cached `static_knowledge` chunks so the next `invoke` re-fetches from all registered
  sources. Essential for long-running processes (web servers, job workers) where knowledge
  sources may be updated at runtime without a process restart.

- **`Phronomy::Configuration#logger`** (#158): New optional configuration attribute. Any
  object responding to `#warn` (e.g. `Rails.logger`) can be assigned. Framework diagnostic
  messages — starting with the unreachable-state warning from `Workflow.define` — are routed
  through this logger instead of writing directly to `$stderr` via `Kernel#warn`.

- **`Phronomy.with_configuration` and `Phronomy.reset_runtime!`** (#206): Two new class
  methods for runtime isolation. `with_configuration` yields the current `Configuration`
  object and restores the original after the block — even on exception — enabling per-request
  overrides and scoped test configuration. `reset_runtime!` stops any running `EventLoop`,
  clears its singleton, and resets configuration to defaults; intended for test suites to
  ensure clean state between examples. `spec_helper.rb` now calls `reset_runtime!` in an
  `after(:each)` hook automatically.

- **`CancellationToken` — cooperative cancellation for agent invocations** (#216):
  New class `Phronomy::CancellationToken` enables cooperative cancellation without
  `Thread#kill`. Tokens are passed via `config: { cancellation_token: token }`.
  `cancel!` marks the token (thread-safe via Mutex); `cancelled?` returns `true`
  once cancelled or once an optional `deadline: Time` has passed. Agents check the
  token in `_invoke_impl` (fail-fast before any LLM call) and again immediately
  before `chat.ask`. `CancellationError` is never retried by the retry policy.
  `dispatch_parallel` and `fan_out` accept `cancellation_token:` and automatically
  inject it into every worker task's config unless the task already supplies its own.

### Added (post-v0.9.0)

- **`Agent::Base#run_as_child` removed** (post-v0.9.0):
  `run_as_child` was introduced when agents had their own FSM.  After `Agent::FSM`
  was removed, the `:child_completed` event payload was silently discarded by
  `FSMSession`, meaning `ctx.answer` was never populated.  The method has been
  removed.  Use `invoke_async + Task#map` instead:

  ```ruby
  # Before (deprecated)
  entry :translate, ->(ctx) { TranslationAgent.new.run_as_child(ctx.query, ctx: ctx) }
  transition from: :translate, on: :child_completed, to: :done

  # After (recommended)
  entry :translate, ->(ctx) {
    TranslationAgent.new.invoke_async(ctx.query).map { |r| ctx.merge(answer: r[:output]) }
  }
  transition from: :translate, to: :done
  ```

- **`Phronomy::Agent::CheckpointStore` — idempotency store for HITL resume** (post-v0.9.0):
  New in-memory store tracks consumed checkpoint IDs. Calling `Agent::Base#resume` twice
  with the same checkpoint raises `Phronomy::CheckpointAlreadyResumedError` instead of
  silently re-executing the approved tool. Custom stores can be injected via
  `agent.checkpoint_store = MyRedis::CheckpointStore.new`. Duck-type contract:
  `consumed?(id)`, `consume!(id)`, and optionally `cleanup!(id)` / `clear!`.

- **`checkpoint_id`, `agent_class`, `requested_at` on `Checkpoint`; `Agent::Base.resume` class method** (post-v0.9.0):
  `Checkpoint` now carries a UUID `checkpoint_id` (idempotency key), `agent_class`
  (fully-qualified class name), and `requested_at` (UTC timestamp). The new class-level
  `Agent::Base.resume(checkpoint, approved:)` method instantiates the correct agent class
  automatically and delegates to `#resume`, simplifying job-queue resume flows.

- **`CheckpointStore#cleanup!` and `#clear!`** (post-v0.9.0):
  Optional methods on the `CheckpointStore` duck-type contract. `cleanup!(checkpoint_id)`
  removes a single checkpoint entry; `clear!` wipes all tracking state.

### Removed

- **`Phronomy::ReactAgent` class removed** (post-v0.9.0):
  Use `Phronomy::Agent::Base` directly. `ReactAgent` had no distinct public API beyond
  `Agent::Base` and was not listed in the stability table.

- **`Phronomy::Agent::FSM` class removed** (post-v0.9.0, internal):
  The agent invocation path is now unified through `Agent::Base#invoke` with inline logic.
  No public API impact.

- **`Phronomy::Agent::Lifecycle::FSMSession` and `::PhaseMachineBuilder` moved to `Workflow` namespace** (post-v0.9.0, internal):
  These internal classes now live at `Phronomy::Workflow::FSMSession` and
  `Phronomy::Workflow::PhaseMachineBuilder`. No public API impact.

- **BREAKING: `Agent::Base#run_as_child` drops `&result_writer` block parameter** (#265):
  The optional block form `run_as_child(input, ctx: ctx) { |r| ctx.answer = r[:output] }`
  is no longer supported. The result is now delivered **exclusively** as the
  `:child_completed` event payload `{ output:, messages:, usage: }`. The parent
  Workflow task is the sole owner of the `WorkflowContext`; no background thread
  writes to it directly. Callers that were using the block to write back into the
  context must update their workflow design (e.g. read the result in the target
  state's entry action after the transition, or store output through an external
  shared resource if needed).

- **BREAKING (internal): `AgentFSM#initialize` drops `result_writer:` keyword** (#265):
  Direct callers of `AgentFSM.new(result_writer: ...)` must remove that keyword.
  This class is considered internal; gem consumers should use `run_as_child` instead.

### Changed

- **`AgentFSM`, `ParallelToolChat`, and `Orchestrator` use `Task`/`TaskGroup` instead of bare `Thread.new`** (#257, #258, #259):
  All three components now spawn async work through the `Task` and `TaskGroup`
  abstractions. This enables cancellation propagation, context threading, and
  `BlockingAdapterPool` routing. No public API changes; behaviour is equivalent.

- **`Thread.current[:phronomy_*]` context propagation replaced with explicit `InvocationContext`** (#260):
  Thread-local keys `phronomy_event_loop_thread`, `phronomy_cancellation_token`,
  and `phronomy_context_version_caches` are no longer used as the primary
  propagation channel. `InvocationContext` is threaded explicitly through call
  stacks. Importantly, `Tool::Base#call` no longer falls back to
  `Thread.current[:phronomy_cancellation_token]`; cancellation is only observed
  when the caller passes `cancellation_token:` explicitly (or when
  `ParallelToolChat` injects it). Tools that relied on the thread-local fallback
  must be updated.

- **`Timeout.timeout` removed from core paths; replaced with `CancellationScope`** (#261):
  `Agent::Base#invoke` and `McpTool::StdioTransport` no longer use `Timeout.timeout`
  (which is unsafe with `Thread.new` and `ensure` blocks). A `CancellationScope`
  with `deadline_in(seconds)` provides equivalent semantics without the thread-
  interruption hazards. `ScopeTimeoutError < TimeoutError` is raised on expiry.

- **RAG/VectorStore blocking I/O placed behind `BlockingAdapterPool` async boundary** (#267):
  `KnowledgeSource#fetch` and all three `VectorStore` backends now execute their
  blocking I/O through `Runtime#blocking_io` when a `Runtime` is present. Callers
  in a synchronous context see no change; callers in an EventLoop context benefit
  from non-blocking scheduler behaviour.


  The cancellation token (passed via `config: { cancellation_token: token }`) is
  now checked at multiple additional points beyond the initial LLM call boundary:
  before each `KnowledgeSource#fetch` in `build_context` (RAG phase); after each
  streaming chunk in `_stream_impl`; before each tool-call batch in
  `ParallelToolChat`; and after each `before_completion` hook. This ensures that
  long-running retrieval, streaming, and tool-dispatch phases respect cancellation
  with minimal latency.

- **`Agent::Orchestrator` uses `CancellationToken` for internal stop flag** (#224):
  The boolean stop flag in `Orchestrator` is replaced with an internal
  `CancellationToken`. FSM session loops perform cooperative cancellation checks
  via `cancelled?`; `Thread#kill` is retained only as a last resort after
  cooperative shutdown.

- **Error taxonomy classes are now raised at the retry boundary** (#204): The classes
  `Phronomy::RateLimitError`, `Phronomy::AuthenticationError`, `Phronomy::ContextLengthError`,
  and `Phronomy::TransportError` (introduced in #149) are now actually raised when the
  corresponding `RubyLLM` exceptions occur. A new internal `ErrorTranslation` concern wraps
  the retry exhaust path and maps `RubyLLM::*` exceptions to their Phronomy counterparts,
  preserving the original exception as `#cause`. **Migration**: callers rescuing
  `RubyLLM::RateLimitError` (or other `RubyLLM::*` errors) directly should migrate to
  `rescue Phronomy::RateLimitError` / `Phronomy::TransportError` etc.

- **`Orchestrator#bounded_map` uses cooperative cancellation before force-kill** (#203):
  Workers now check a shared `cancelled` flag at each loop iteration and stop picking up new
  tasks once the timeout deadline passes. A 0.5 s grace period is given to in-flight workers
  before `Thread#kill` is used as a last resort. `EventLoop#stop` similarly logs a warning
  via `Phronomy.configuration.logger` when force-kill is triggered.

- **`Orchestrator#bounded_map` timeout deadline uses monotonic clock** (#209): Replaced
  `Time.now` deadline arithmetic with `Process.clock_gettime(Process::CLOCK_MONOTONIC)` to
  avoid sensitivity to NTP adjustments, DST transitions, and system-clock changes that could
  inflate or deflate effective timeouts.

- **`EventLoop` warns on events for unknown `target_id`**: When the event loop receives an
  event whose `target_id` does not match any registered session, a warning is emitted instead
  of silently discarding the event.

- **`VectorStore#search` validates `k` is a positive integer**: All three backends
  (`InMemory`, `RedisSearch`, `Pgvector`) now raise `ArgumentError` immediately when `k` is
  not a positive integer, providing a clear error instead of a silent empty result or an
  obscure database error.

- **`max_parallel_tools` DSL**: Agents can cap the number of concurrent tool-call threads
  with `max_parallel_tools N` in the class body. Useful for rate-limiting external API calls.
  The default is **10** (inheriting from `Base`); set explicitly to raise or lower the cap.

- **`max_parallel_tools` and `invoke_timeout` DSL argument validation** (#152): Both setters
  now raise `ArgumentError` at class-definition time if the supplied value is invalid
  (`max_parallel_tools` requires an `Integer >= 1`; `invoke_timeout` requires a positive
  `Numeric`), surfacing configuration mistakes immediately.

- **`on_error :suppress` — canonical alias for `:return_empty`** (#165): `:suppress` is the
  new preferred name for the error-suppression behaviour in `Tool::Base`. `:return_empty`
  continues to function but emits a deprecation warning and will be removed in a future major
  release. Migrate by replacing `on_error :return_empty` with `on_error :suppress`.

- **Tool nested object properties injected into JSON Schema** (#162): `Tool::Base#params_schema`
  now recursively serialises nested `:object` param specs (including `enum` constraints and
  further nesting) into the JSON Schema `properties` structure forwarded to the LLM,
  enabling accurate structured argument generation for complex tool parameters.

### Fixed

- **`tool_name` preserved in `Orchestrator#prepare_tool_class` anonymous subclass wrapper**:
  When `Orchestrator#prepare_tool_class` wrapped a subagent tool in an anonymous
  subclass (`Class.new(prepared)`), the class-level instance variable `@tool_name`
  was not inherited, causing the wrapper's `tool_name` to return `nil`. RubyLLM
  then registered the tool under a `nil` key, making it unreachable when the LLM
  called it by name. The fix captures the effective name before subclassing and
  calls `tool_name effective_name` explicitly inside the anonymous class body —
  the same pattern already used by the approval-gate wrapper.

- **`EventLoop#start` is now idempotent; stale `:__stop__` sentinel race fixed** (#203):
  Calling `start` on an already-running `EventLoop` is now a no-op. Fixed a race condition
  where `stop` setting `@running = false` before the worker thread was scheduled left the
  `:__stop__` sentinel unconsumed in the queue; a subsequent `start` would then immediately
  terminate the new thread upon popping the stale sentinel. The sentinel is now treated as a
  pure unblock signal for `queue.pop` (`next` instead of `break`) — loop termination is
  driven solely by `@running`.

- **`trace_pii: false` now redacts both input and output**: Previously only the user input
  was redacted when `trace_pii` was `false`; LLM responses and tool results were still
  forwarded to the tracing backend unredacted. Both sides are now replaced with `[REDACTED]`.

- **`StdioTransport` — `read_timeout` prevents indefinite blocking**: A configurable
  `read_timeout` (default 30 s) is now enforced on MCP stdio reads. A silent child process
  could previously block the calling thread forever.

- **MCP schema `required` and `enum` constraints propagated to `param` DSL**:
  `McpTool.from_server` now copies `required` and `enum` constraints from the MCP JSON Schema
  into the generated `param` declarations so downstream validation sees them.

- **`FSMSession` notifies parent when child `AgentFSM` fails**: An unhandled error in a child
  `AgentFSM` now correctly notifies the parent `FSMSession`, preventing it from waiting
  indefinitely for a completion event that will never arrive.

- **`WorkflowContext.field` rejects plain `Array` or `Hash` defaults**: Passing a plain `Array`
  or `Hash` as a field default now raises `ArgumentError` at class-definition time,
  preventing accidental state sharing across workflow invocations. Other mutable objects
  are not checked. Wrap collection defaults in a Proc: `default: -> { [] }`.

- **Tool aliases inherited by `Agent` subclasses**: `tool_aliases` declared in a parent
  `Agent::Base` subclass are now correctly merged into subclasses rather than being silently
  dropped.

- **`ReactAgent` output selection skips tool-role messages**: The final output selection
  logic no longer misidentifies `tool`-role messages as the assistant response, fixing
  spurious tool-call JSON appearing in `result[:output]`.

- **Thread-local context cache cleaned up after each `invoke`** (#128): `Agent::Base#invoke`
  previously leaked thread-local context cache entries after each call, causing stale cache
  hits in long-lived threads. The cache is now cleared in an `ensure` block.

- **Unknown tool parameters are rejected** (#130): `Tool::Base#call` now raises
  `ArgumentError` when keyword arguments not declared via the `param` DSL are passed, instead
  of forwarding them silently to `execute`.

- **`EventLoop#stop` uses cooperative shutdown instead of `Thread#kill`** (#135):
  `Thread#kill` bypasses `ensure` blocks and is unsafe. The event loop now sets a sentinel
  flag and joins the worker thread, allowing it to flush pending events before termination.

- **`Orchestrator` propagates parent `config` and `thread_id` to sub-agents** (#132):
  Sub-agents spawned via `dispatch` or `dispatch_parallel` now inherit the caller's `config`
  hash and `thread_id`, enabling correct memory isolation and distributed tracing in
  multi-agent pipelines.

- **`Agent::Base` caches `static_knowledge` fetch at the class level** (#127): The RAG
  knowledge fetch was re-executed on every `invoke`. The result is now memoized at the class
  level (`@static_knowledge_chunks ||= ...`), eliminating redundant vector-store queries.
  The cache is **not** invalidated automatically when source content changes; call
  `static_knowledge_refresh!` explicitly to force a reload.

- **`WorkflowContext#initialize` raises on unknown field keys** (#121): Passing an
  unrecognised key to `WorkflowContext.new` was silently ignored. The constructor now raises
  `ArgumentError`, surfacing typos and API mismatches immediately.

- **`WorkflowContext#merge` raises `ArgumentError` for unknown field keys** (#154): Passing
  an unrecognised key to `WorkflowContext#merge` was silently ignored. The method now raises
  `ArgumentError`, matching the guard added to `#initialize` in #121.

- **`WorkflowContext#deep_dup_value` rescues `TypeError` for non-dupable objects** (#156):
  Objects that raise `TypeError` from `#dup` (e.g. `Method`, frozen `Proc`, `Integer`,
  `Symbol`) are now returned as-is instead of crashing.

- **`Workflow.define` raises for undefined `from:` state in transitions** (#157): Transitions
  that reference a `from:` state not declared in the DSL now raise `ArgumentError` at
  build time, complementing the existing check for undefined `to:` targets.

- **`Workflow.define` unreachable-state warning routes through configured logger** (#158):
  The diagnostic warning for unreachable states now uses `Phronomy.configuration.logger`
  when set, falling back to `Kernel#warn`. Previously the warning always went to `$stderr`.

- **`require "set"` added to `workflow.rb`** (#159): Eliminates an implicit dependency on
  `Set` being pre-loaded by another gem.

- **`Tool::Base#validate_nested_object` rejects undeclared extra keys** (#166): Keys present
  in the LLM-supplied hash but absent from the tool's nested `param` schema now produce a
  validation error rather than being silently forwarded.

- **`WorkflowContext#merge` deep-copies unchanged fields** (#123): Fields absent from the
  `merge` argument were previously shared by reference with the original context, allowing
  one branch to mutate another branch's state. All fields are now independently copied.

- **Robust metadata parsing in `VectorStore::Pgvector#search`** (#139): Metadata stored as a
  PostgreSQL JSON string is now parsed correctly regardless of whether the database driver
  returns a `String` or an already-decoded `Hash`.

- **`OutputParser::JsonParser` tries all fenced code blocks before falling back** (#146):
  The parser now scans every fenced block in the LLM response (in order) and returns the
  first one that parses as valid JSON, rather than only checking the first block. This
  improves reliability with models that include prose before the JSON block.

- **`on_error: :return_empty` emits a warning and returns a descriptive string** (#147):
  Errors in tools that declare `on_error :return_empty` are now logged to `warn` before the
  tool returns. The placeholder string includes the tool name and a brief reason, making
  silent failures easier to diagnose.

- **`context_version_cache` accessible after `invoke` completes**: The thread-local cache is
  cleared in `invoke`'s `ensure` block, which caused `context_version_cache` to return `nil`
  immediately after every call. The value is now persisted in `@last_context_version_cache`
  so it remains readable post-invoke.

- **`WorkflowContext` field type `:merge` comment corrected**: The inline comment incorrectly
  described `:merge` as a deep-merge. It performs a shallow merge (`Hash#merge`). The comment
  has been updated.

- **`WorkflowContext` return value from entry actions now adopted in EventLoop mode** (#107):
  `FSMSession` previously discarded the `WorkflowContext` returned by entry action callables,
  causing `s.merge(...)` updates to be silently lost when `event_loop = true`. The context is
  now correctly propagated, bringing EventLoop semantics in line with the synchronous
  `WorkflowRunner`. Regression tests added in `spec/phronomy/fsm_session_spec.rb` (unit)
  and `spec/integration/workflow_spec.rb` (integration, both sync and EventLoop paths).

### Documentation

- **`trace_pii = false` description corrected** (#153): The inline comment and README Note
  now correctly state that both the input and the output are redacted.

- **`invoke_timeout` is a wait timeout, not cancellation** (#163): YARD comment now
  explicitly documents that the background agent thread and in-flight LLM/tool calls are
  **not** interrupted when the timeout fires. Only the caller receives `TimeoutError`.

- **`context_version_cache` thread-safety limitation documented** (#161): A NOTE in the YARD
  comment explains that the per-instance cache is not thread-safe when the same agent
  instance is shared across threads.

- **`trace_pii` option documented in README**: The `trace_pii:` configuration key and its
  behaviour (default `false`, redacts input and output in trace records) is now described in
  the Configuration section of the README.

- **CJK token under-count warning in `TokenEstimator`**: A note in both the source and README
  explains that the byte-based heuristic under-counts CJK characters by roughly 3×. Users
  processing Chinese, Japanese, or Korean content should apply a correction factor or use a
  model-specific tokenizer.

- **Stability labels, `reset_configuration!` caveat, CI, and gemspec** (#140 / #141 / #142 / #143 / #148 / #150):
  README stability table revised for several APIs. `Phronomy.reset_configuration!` now carries
  a warning that it is intended for test isolation only. Gemspec upper bounds added for
  `ruby_llm` and `pg`. `ruby head` added to the CI test matrix. README API smoke tests added.

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
