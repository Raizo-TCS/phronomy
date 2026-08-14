# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release history for 0.14.0 and earlier is archived in
[`docs/changelog/0.14-and-earlier.md`](docs/changelog/0.14-and-earlier.md).

---

## [Unreleased]

### Unified Persistence and durable-state ownership

#### Added

- `Persistence#workflow_states` with optimistic revision checks for durable Workflow snapshots.
- Runtime-local Agent Activation ownership; live `AgentExecutionActivation` values are no longer Persistence repositories.
- Owner-aware Workflow admission keyed by durable `thread_id` and owned by a per-execution internal `fsm_session_id`.
- ADR-014 and the 0.19 migration guide for the unified durable-state architecture.

#### Changed

- Live Agent instances now remain the authoritative logical-state owners after hydration. Context Policy and follow-up Manifest preparation use the Agent-local root, Journal view, and Activation state instead of reloading mutable Agent state for freshness.
- `Phronomy.configuration.persistence` is the global durable backend for Workflows and for Agent `new`/`create` calls that do not explicitly inject another Persistence instance.
- Agent durable writes use optimistic revision/Journal-position guardrails; conflicting external writes fail instead of being silently reloaded or merged.
- Approval suspension/resume preserves the same live Agent/Activation/AgentInvocation. Class-level approval convenience routing resolves that live owner from Runtime instead of loading another Agent.
- Workflow durable I/O runs outside EventLoop through OffloadPool, while `thread_id` admission remains owned until terminal/halted snapshot persistence completes.
- Workflow `thread_id`, Runtime `fsm_session_id`, and application `session_id` now have distinct responsibilities.

#### Removed

- `Phronomy::StateStore`, `StateStore::InMemory`, `Workflow.define(..., state_store:)`, `Configuration#state_store`, and per-invocation `config[:state_store]`.
- `Persistence#activations`; ActivationRegistry is transient Runtime state.

### OffloadPool execution model

#### Changed

- Renamed `BlockingAdapterPool` to `OffloadPool` and `Runtime#blocking_io` to
  `Runtime#offload`; configuration keys now use `offload_pool_size` and
  `offload_queue_size`, and metrics now use `offload_pool_*` names.
- Simplified Tool execution modes to `:cooperative` and `:offloaded`.
  Workload classification (I/O-bound versus CPU-bound) is application-owned.
- CPU-bound synchronous Tools may execute through the bounded OffloadPool;
  Phronomy does not guarantee CPU isolation, CPU/I/O fairness, or parallel
  speedup for pure Ruby CPU work.
- Framework-owned EventLoop-origin offload submissions use non-blocking queue
  admission so a full worker queue raises backpressure instead of blocking
  the EventLoop control thread.
- Submit cancellation now settles the caller-facing `PendingOperation`
  immediately. Cancellation before worker start prevents execution;
  cancellation after worker start marks the operation abandoned while allowing
  the synchronous worker to finish without asynchronous `Thread#raise`.
- Monotonic deadlines carried by an OffloadPool submit cancellation token are
  promoted by the Runtime timer queue, so cancellation completion does not
  require a polling Thread.
- Independent notification callbacks now isolate subscriber failures. An
  `StandardError` from one `CancellationToken#on_cancel`, `Task#on_complete`, or
  `PendingOperation#on_complete` callback is logged and does not suppress later
  subscribers.
- `PendingOperation#blocking_wait(timeout:)` remains a waiter-local synchronous
  timeout only. It does not settle or cancel the operation; operation-wide
  cancellation is represented only by `OffloadPool#submit(cancellation_token:)`.
- `offload_pool_abandoned_total` is the cumulative number of operations whose
  caller-facing submit timeout or cancellation settled after worker execution
  started. `offload_pool_abandoned_active` is the current number of those
  abandoned operations whose synchronous workers still occupy pool capacity.
- Named Runtime pools remain available for application-managed resource
  isolation and capacity planning.

#### Removed

- Tool execution modes `:blocking_io`, `:cpu_bound`, and `:external_process`.
- `Runtime#blocking_io`, `blocking_io_pool_size`, and
  `blocking_io_queue_size`.
- Waiter-local `cancellation_token:` from `PendingOperation#blocking_wait`.
  The low-level synchronous bridge continues to support waiter-local `timeout:`.


### EventLoop-first runtime cleanup

#### Added

- Event-driven Agent-as-Tool completion: child Agents now run through their own
  Agent FSMSession and settle the parent ToolInvocation through a completion
  event without holding a OffloadPool worker while waiting.
- Architecture regression coverage for the production Thread/Fiber boundary,
  test-only API separation, current concurrency documentation, and Agent-as-Tool
  pool-starvation behavior.

#### Changed

- `FSMSession + EventLoop` is the single framework control plane for Agent,
  Workflow, ToolInvocation, and MultiAgent lifecycle coordination.
- `Task` is a completion handle only; it does not execute work.
- `execution_mode :cooperative` now means short EventLoop-safe synchronous work,
  or a specialized Tool that starts another Phronomy asynchronous lifecycle and
  returns a completion handle immediately.
- `Tool#call_async` for ordinary cooperative Tools no longer consumes a
  OffloadPool worker. `:offloaded` remains the worker-pool route.
- Framework-owned short in-memory Tools (handoff sentinels, TeamCoordinator
  queue controls, and SharedState store access) explicitly declare
  `execution_mode :cooperative` instead of using the blocking-I/O default.
- MultiAgent fan-out uses a FanOut FSMSession rather than per-child OS Threads.
- `TimerQueue` is driven by EventLoop and owns no Thread.
- Eval support is test infrastructure under `Phronomy::Testing::Eval` and is no
  longer part of the product API compatibility snapshot or README feature set.
- The `dispatch_parallel` regression benchmark now uses thread-free fake child
  completion so it measures FanOut/EventLoop overhead rather than fake Thread
  creation. Its separate CancellationToken contention benchmark intentionally
  continues to use application Threads.

#### Removed

- Active runtime-backend/scheduler documentation for the removed
  `Runtime#spawn`, TaskGroup, Thread/Fiber/Immediate Task backends, and
  configurable runtime backends.
- Product-facing Eval design documentation.

### Agent Context / Knowledge cleanup

#### Added

- Journal-backed persistent Agent Knowledge via creation-time `knowledge:` and
  post-creation `Agent#add_knowledge`.
- `Agent#clear_knowledge!` for logical Knowledge invalidation without deleting
  append-only Journal history.
- ADR-013, defining persistent Knowledge as optional Context candidates selected
  through the Manifest-first Context Policy pipeline.

#### Changed

- Persistent Knowledge and `before_llm_input` segment candidates now participate
  in Context Policy and token-budget selection instead of being injected as
  mandatory system context.
- `clear_transcript!`, `clear_knowledge!`, and `reset_context!` now have distinct
  transcript/Knowledge lifecycle semantics.
- Active Context tests, integration fixtures, benchmarks, mutation subjects,
  design documents, and API snapshots now describe the canonical
  Journal -> ContextCandidate -> Context Policy -> Manifest architecture.

#### Removed

- `Phronomy::KnowledgeSource`, `Knowledge::Base`, `StaticKnowledge`, and
  `EntityKnowledge`.
- `static_knowledge*`, `add_knowledge_source`, `instance_knowledge_chunks`,
  `Knowledge#static?`, `StaticKnowledge#source`, and the class-level static
  Knowledge cache/fetch abstraction.
- `Agent#clear_memory!` and `AgentRoot#memory_generation`.
- Remaining no-op ContextVersionCache tests, fake legacy-import Context tests,
  obsolete Memory/context integration helpers, legacy `:llm_message` benchmark
  categories, and stale Agent `messages:` test-double signatures.

### Phase 3 cleanup

#### Changed

- Active documentation, compatibility snapshots, benchmarks, integration fixtures,
  and mutation targets now describe the Manifest-first Context architecture.
- The Context benchmark now measures `Agent::ContextAssembler` and
  `ContextPolicies::Default` instead of the removed legacy Assembler.
- ADR-011 is marked Superseded by ADR-012; its historical analysis is retained.

#### Removed

- Remaining active compatibility references to `context_overhead`,
  `LlmContextWindow::Assembler`, `ContextVersionCache`, Tool
  `on_error :return_empty`, `force_kill:`, `runtime_backend :cooperative`,
  the `Runtime.instance=` setter, tools-splat registration, and wall-clock
  `CancellationToken.new(deadline:)`.
- Obsolete legacy Assembler / ContextVersionCache executable specs.

### Documentation

- Reduced `README.md` to the project entry point and moved long-form setup,
  feature stability, runtime/concurrency, and migration guidance into focused
  documents under `docs/`.
- Archived changelog history for 0.14.0 and earlier in
  `docs/changelog/0.14-and-earlier.md`; `CHANGELOG.md` now carries Unreleased
  work and the most recent release history.


---

## [0.16.0] - 2026-08-08

### Added

- Stateful Agent identity and persistence:
  - Every concrete Agent definition declares a stable `agent_definition id:, version:`.
  - Every Agent instance has a stable `agent_id`.
  - `Agent::Base.create` creates a persistent Agent instance.
  - `Agent::Base.load` restores an Agent from a shared Persistence backend.
  - `Agent#agent_root`, `#transcript`, `#clear_transcript!`, `#clear_memory!`,
    `#reset_context!`, `#close!`, and `#purge!` provide explicit state lifecycle operations.

- Persistence-backed Agent execution state:
  - Agent executions have stable `execution_id` values and are persisted separately from the owning Agent.
  - Suspended approval executions remain represented in Persistence.
  - Resuming after process loss still requires future durable activation rehydration support.

- Canonical Complete Execution Log:
  - Phronomy records observed logical execution facts in an append-only Agent Journal.
  - Provider assistant responses preserve assistant content and all Tool Calls as one logical assistant message.
  - Raw Tool return values and the Tool-role messages sent back to the LLM are represented as separate execution facts.

- Per-LLM-call canonical Manifests:
  - Each LLM Call is assembled from a canonical Manifest.
  - The Manifest records the logical input selected for that specific LLM Call.
  - Runtime RubyLLM messages are materialized from the Manifest rather than treated as the source of truth.

- Context Policy domain:
  - Context candidates are selected from canonical history without deleting the underlying Journal.
  - Tool Call / Tool message protocol dependencies are selected atomically.
  - Required context is validated independently from optional historical context.
  - `ContextBudgetExceededError` is raised when required context cannot fit in the available model budget.

- Context import for stateful Agents:
  - Existing user / assistant / Tool history can be supplied through Agent creation context.
  - Imported assistant messages retain their original logical message boundary and Tool Calls.
  - Invalid Tool protocol histories are rejected instead of being guessed or repaired.

- `Workflow#signal(thread_id:, event:, payload:)` for FIFO delivery to a live
  Workflow FSMSession.
- Workflow transition `action:` callbacks, executed after source exit callbacks
  and before target entry callbacks. Actions may accept `(context)` or
  `(context, event)` and may return a replacement Workflow context.
- `InvalidAsyncWorkflowActionError` and
  `InvalidAsyncTransitionActionError`. Transition actions may start async work,
  but returning a `Phronomy::Task` is rejected rather than implicitly awaited.
- Symmetric Agent `on_event:` support for `invoke_async` and `stream_async`;
  streaming differs only by adding `:token` events.
- `Agent#approve_async` and `Agent::Base.approve_async` resume a suspended
  AgentInvocation without blocking the caller and return a `Phronomy::Task`.
- Streaming invocations resumed through `approve_async` continue to deliver
  terminal stream events on the Runtime-owned EventLoop thread.
- `Phronomy::Metrics.snapshot` now reports `event_loop_queue_depth` and
  `event_loop_queue_max_depth`.
- EventLoop emits a rate-limited warning when its shared event queue reaches
  1,000 pending entries. Events are observed only; they are not dropped.

### Changed

- Agent instances are now always stateful and Persistence-backed.

- Conversation history ownership has moved from the caller to the Agent:
  callers no longer need to pass the previous `messages` array back on every invocation.
  Completed invocation results may still expose `result[:messages]` as a materialized
  transcript projection.

- `agent_definition id:, version:` is required for concrete Agent definitions.
  Loading persisted Agent state validates the stored definition identity and version
  against the runtime Agent class.

- Context-window management is now Manifest-first:
  canonical Agent history is retained in the Journal while each LLM Call receives
  only the context selected for its Manifest.

- Context pruning no longer means deleting or mutating historical Agent messages.
  Context Policy omission affects only the current LLM Call input.

- Tool execution results and Tool protocol messages are no longer treated as the
  same value. The raw Tool return value is retained as an execution fact while the
  exact Tool-role message remains independently available for LLM context assembly.

- `thread_id` is an execution/correlation identifier rather than the owner of
  conversation state. Persistent Agent identity is defined by `agent_id`.

- `context_overhead` is retained only for the legacy `build_context` path.
  Manifest-first context assembly accounts for actual mandatory context instead of
  reserving this value as Tool/system-prompt overhead.

- Phronomy now requires `ruby_llm >= 1.15, < 2` so Provider assistant messages can
  be captured before Agent-owned Tool execution begins.

- Refactor: `Agent::AsyncEventApi` is now the single implementation of
  `invoke`, `invoke_async`, `stream`, `stream_async`, and their session
  lifecycle helpers (`_start_invocation`, `_handle_agent_completion`,
  `_register_tool_invocation_session`, `_start_approval_resume`). The
  duplicate definitions in `Agent::Base` have been removed. No public
  behavior change is intended.
- Remove `faraday` and `event_stream_parser` from gemspec declared
  dependencies; both are transitive dependencies of `ruby_llm` and are
  not used directly by phronomy.
- `Workflow#invoke`, `#invoke_async`, and `#stream` now share context
  preparation, StateStore load/save, EventLoop registration, and FSMSession
  execution.
- Workflow entry and transition action return values use the same
  `set_graph_metadata` context protocol as FSMSession, including duck-typed
  context replacements.
- Agent terminal outcomes are delivered to `on_event` before the returned Task
  is settled. `Task#on_complete`, `wait_result`, and cancellation remain active.
- Mapping Agent events to Workflow events, correlation, stale-event handling,
  result persistence, and external Task cancellation are application concerns.
- LLM transport timeout, transient-error retry, backoff, and jitter are delegated
  to RubyLLM or another configured LLM adapter. Phronomy only translates the
  adapter's final provider error.
- Agent execution now creates exactly one AgentInvocation session per call.
- Parallel Tool mode dispatches the complete authorized ToolCall batch; Runtime's
  bounded workers and queues remain the coarse process-protection boundary.
- Caller-provided deadline and cancellation-token propagation is unchanged.

### Removed

- Caller-managed `messages:` continuation from the Agent invocation API.
  Stateful Agent history is now obtained from the Agent's persisted Journal.

- `Agent::Base#trim_messages` and the legacy Agent-level message-trimming model.
  Context selection is performed by the Context Policy / Manifest assembly path.

- The assumption that `build_context` and the legacy `LlmContextWindow::Assembler`
  are the long-term single authority for LLM input. ADR-012 defines the replacement
  Journal / Context Policy / Manifest architecture.

- Implicit awaiting of Task-returning Workflow/Agent/Tool entry actions and the
  Workflow `action_timeout:` DSL. Entry actions are synchronous RTC callbacks.
- The duplicate caller-thread `WorkflowRunner#run_workflow` execution path.
- Agent-wide automatic replay: `Agent::Base.retry_policy` and the `Retryable`
  concern. A failed AgentInvocation is no longer started again by Phronomy.
- Agent-class `invoke_timeout`. Callers that need a root deadline should pass an
  `InvocationContext` with `deadline:` or `cancellation_token:`.
- Phronomy LLM operation timeout `config[:llm_timeout]`; configure RubyLLM's
  `request_timeout` instead.
- Generic Tool retry DSL (`retry_on`, `retry_policies`) and
  `config[:tool_timeout]`; Tool/client implementations own their transport policy.
- `max_parallel_tools` from Agent, AgentInvocation, ParallelToolChat, and
  InvocationContext.
- Unused `InvocationContext#provider_limits`.
- `Configuration#stream_queue_max_size`, which no longer affected the
  Runtime-owned EventLoop streaming path.

### Fixed

- `Agent#approve` now rejects EventLoop re-entry instead of synchronously waiting
  for work that can only be dispatched by that same EventLoop.
