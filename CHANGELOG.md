# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release history for 0.14.0 and earlier is archived in
[`docs/changelog/0.14-and-earlier.md`](docs/changelog/0.14-and-earlier.md).

---

## [Unreleased]

### Four-category Context Policy SPI and transaction boundary (ACS-04)

#### Added

- Public immutable `ContextPolicyInput` typed values for `instruction`,
  `knowledge`, `tools`, and indivisibly grouped `conversation`.
- Agent-class `context_policy <instance>` binding for reusable Application
  Context strategies, with built-in Default fallback.
- Small ContextPolicy helpers for current-call generated instruction, Knowledge,
  and conversation items.
- Framework trace boundary around ContextPolicy invocation without standard-trace
  inclusion of full Policy input/Plan content.

#### Changed

- `ContextPlan` now directly carries ordered output material in the same four
  semantic categories.
- Default Policy uses deterministic recent-conversation / stable-fit Knowledge
  selection with an approximately 60/40 variable budget split and preserves the
  effective Tool set.
- Custom Policy may select/reorder a subset of effective Tools; arbitrary
  schema-only runtime Tool creation remains outside ACS-04 because durable
  runtime Tool identity/wiring is not defined.
- ContextPolicy executes outside Phronomy Persistence transactions. The durable
  base/revision is revalidated before the short Manifest/execution commit.
- Context assembly policy version is `8`.

#### Removed

- `ContextRequest`, `ContextPolicyDescriptor`, `ContextPolicyRegistry`, and
  `DerivedContentSpec`.
- Intermediate selection-unit/policy-parts machinery superseded by the typed
  four-category SPI: `Selection::Unit`, `Selection::Validator`,
  `DependencyAwareUnitBuilder`, `RequiredContextResolver`,
  `RecentFirstSelector`, and `TokenBudgetPacker`.
- Descriptor persistence/reconstruction and old `ContextPlan` fields
  `selected_unit_ids`, `derived_contents`, `ordering_hints`, and
  `policy_descriptor`.

### Workflow Runtime admission and durable terminal barrier (ACS-13)

#### Added

- ADR-026 defining opaque process-local Workflow admission ownership,
  admission-before-hydration ordering, and FSMSession-integrated terminal
  persistence.
- Explicit Workflow terminal persistence outcomes: known success, known failure,
  and fail-closed outcome uncertainty.

#### Changed

- Workflow admission ownership no longer reuses the future `fsm_session_id`.
  EventLoop acquires a separate opaque owner token before durable load and binds
  the concrete FSMSession routing ID only after hydration.
- Durable Workflow halt/completion now remains nonterminal while the final
  snapshot is saved. The save result returns to the same FSMSession, and only a
  known-successful result permits `HALTED` / `COMPLETED`, admission release, and
  caller Task settlement.
- Portable known Persistence failures follow the Workflow error path. An
  arbitrary storage/transport error whose commit outcome is not established is
  treated as outcome-unknown: the success barrier stays closed and the
  `workflow_instance_id` admission remains fail-closed/recovery-required.
- Workflow persistence result handling is backend-topology neutral; the FSM does
  not depend on local/network/database transport details.

### Process-local Agent ownership and Runtime admission (ACS-12)

#### Added

- ADR-025 defining one mutable live Agent owner per `agent_id` per Runtime and
  EventLoop-owned same-process top-level execution admission.
- `Agent::Base.get(agent_id)` for process-local live-owner lookup without
  Persistence I/O.
- `AgentAlreadyExistsError` for create/new identity conflicts and
  `AgentPurgedError` for stale references after successful purge.

#### Changed

- Repeated `Agent.load(agent_id, persistence:)` returns the exact existing live
  Agent object; a durable-only Agent is hydrated once, and a missing durable
  Agent remains a strict `Persistence::NotFoundError`.
- `new` / `create` mean creation only and reject an identity that is already
  live or already durable instead of materializing a second mutable owner.
- EventLoop acquires the same-Agent top-level execution slot before initial
  Offload/Persistence work. Suspension retains that slot; known durable terminal
  completion releases it; uncertain durable outcomes remain fail-closed.
- Persistence `executions.create_active` / atomic admission remains the durable
  second line of integrity defense rather than the primary same-process lock.
- Runtime-lifetime Agent ownership is released on clean Runtime shutdown.
  Successful `purge!` is the explicit earlier destruction boundary and makes
  the stale Agent object permanently unusable before the identity can be reused.

### EventLoop single-writer Agent Runtime (ACS-11)

#### Added

- ADR-024 defining EventLoop as the single writer of Phronomy-managed live
  Agent execution state and operation-specific Offload command/result apply.
- Runtime read-only Agent execution-owner lookup for approval/live-owner
  routing without exposing mutable execution internals.
- Provider result authority using current FSMSession/FSM state plus semantic
  `llm_call_id`; stale Provider results are consumed without advancing the FSM.

#### Changed

- Agent initial preparation, follow-up Manifest preparation, approval resume,
  and terminal durable commits now return values from OffloadPool and apply
  committed live-state advances only on EventLoop.
- AgentInvocation owns FSM-local uncommitted Provider/Tool/runtime facts.
- Tool authorization captures Agent identity and Tool description data before
  worker execution; the authorization worker receives no live Agent, Tool, or
  ToolInvocation reference. Application-owned approval/facts/requirement
  callables remain explicit behavior handles.
- `ApprovalEvaluationRequest` is value-only: Agent identity is exposed as
  `agent_id`, `agent_definition_id`, and `agent_definition_version`; Tool
  identity/description is exposed through `tool_name` / `tool_schema`.
- Tool authorization/execution outcomes carry semantic `tool_invocation_id`
  and are applied by the Tool FSMSession.

#### Removed

- `AgentExecutionActivation`, `Agent::ActivationRegistry`,
  `Runtime#__agent_activations`, and the `phronomy_activation` config bridge.
- Live-object accessors `ApprovalEvaluationRequest#agent` and
  `ApprovalEvaluationRequest#tool`; approval policies use value identity and
  Tool-description fields instead.


### Semantic Multi-Agent Handoff and shared Selection

#### Added

- `Phronomy::MultiAgent::HandoffPolicy` with required, forbidden, and selectable
  transfer rules for current request, history, Knowledge, and Tool exchanges.
- `Phronomy::MultiAgent::Runner.new(main_agent:, handoffs:)` as the public
  semantic Handoff coordinator.
- Typed private Handoff request/context/provenance values, explicit
  `AgentExecution` `:handed_off` terminal semantics, and Runtime/EventLoop-owned
  active-Agent coordination.
- Shared `Phronomy::Agent::Selection::Candidate`, `Unit`, `Constraint`, and
  validation machinery for Context and Handoff selection.
- ADR-016 and the 0.22 migration guide for the semantic Handoff clean break.

#### Changed

- Handoff is now an explicit Source-to-Target responsibility transfer rather
  than sentinel Tool-result routing. Generated Handoff Tool names are private
  transport details only.
- Handoff Context is projected from the effective Source Manifest, materialized
  immutably with provenance, and may cross Agents backed by different Persistence
  adapters without adopting Source material into Target Journal/Knowledge.
- Target Context Policy remains the final per-LLM-call selection authority;
  transferred material enters Target assembly as selectable Context candidates.
- The active Target persists across user turns and Runner-facade recreation while
  the same main Agent instance and Runtime remain alive. Runtime/process reset
  intentionally does not restore active-Agent continuation.
- Context assembly policy version is now `7` for the shared Selection and
  Handoff-Context contract.

#### Removed

- `Phronomy::Agent::Runner`, the `agents:` / `routes:` Runner API, sentinel-map
  routing, and Agent-owned `_add_handoff_tool` / `_handoff_tools` mutation.
- `Phronomy::Agent::ContextCandidate` and
  `Phronomy::Agent::ContextSelectionUnit`; internal callers use the shared
  `Agent::Selection` model without compatibility aliases.

### Unified Persistence and durable-state ownership

#### Added

- `Persistence#workflow_states` with optimistic revision checks for durable Workflow snapshots.
- Runtime-local Agent execution ownership outside Persistence; ACS-11 now places the mutable live-state authority on EventLoop.
- `Agent::Base.live_for_execution(execution_id)` for resolving the current process's live owner Agent without reloading Agent or Execution state from Persistence.
- Owner-aware Workflow admission keyed by durable `workflow_instance_id`; ACS-13 now uses a Runtime-only opaque owner token that is separate from concrete `fsm_session_id` routing.
- ADR-014 and the 0.19 migration guide for the unified durable-state architecture.

#### Changed

- Live Agent instances remain authoritative for AgentRoot/Journal state after hydration, while EventLoop owns active execution-state mutation. Context Policy and follow-up Manifest preparation use those local views instead of reloading mutable Agent state for freshness.
- `Phronomy.configuration.persistence` is the global durable backend for Workflows and for Agent `new`/`create` calls that do not explicitly inject another Persistence instance.
- Agent durable writes use optimistic revision/Journal-position guardrails; conflicting external writes fail instead of being silently reloaded or merged.
- Approval suspension/resume preserves the same process-local Agent/AgentInvocation owner. Approval remains an Agent-instance operation; callers with only an `execution_id` resolve the EventLoop-backed live owner with `Agent::Base.live_for_execution` (or the expected concrete Agent class) before calling `agent.approve` / `agent.approve_async`.
- Workflow durable I/O runs outside EventLoop through OffloadPool. Terminal/halted snapshot persistence now completes inside the owning FSMSession lifecycle; only a known-successful save permits normal terminalization and admission release. Workflow admission remains process-local; optimistic revisions detect stale commits across processes but do not prevent duplicate execution or undo already-performed external side effects.
- Workflow `workflow_instance_id` is distinct from one concrete Runtime FSMSession identity; generic application `session_id` is not a Phronomy core domain identity.

#### Removed

- `Phronomy::StateStore`, `StateStore::InMemory`, `Workflow.define(..., state_store:)`, `Configuration#state_store`, and per-invocation `config[:state_store]`.
- `Persistence#activations`; live Agent execution state is Runtime-only. The transitional ActivationRegistry is subsequently removed by ACS-11.
- Class-level `Agent::Base.approve` / `Agent::Base.approve_async` routing APIs and their caller-supplied `persistence:` argument; approval execution now goes through the resolved live Agent instance.

### Public API façade and typed contracts

#### Added

- `Phronomy::Tool::Base` as the application-facing Tool authoring façade. It is
  an exact alias of `Phronomy::Agent::Context::Capability::Base`, so existing
  Tool definitions remain compatible and share the same class identity/DSL state.
- Initial hand-written RBS signatures for the primary application API and
  explicit extension SPIs, with a dedicated RBS validation CI job.
- ADR-015 defining Tool façade ownership, the LLMAdapter SPI, RBS scope, and
  extension dependency direction.

#### Changed

- `Phronomy::LLMAdapter::Base#complete` and `#stream` are explicit Beta extension
  SPI methods. Phronomy continues to own `complete_async` / `stream_async` and
  OffloadPool integration.
- VectorStore and Embeddings backends expose synchronous implementation contracts;
  their framework-provided async convenience methods offload through Phronomy and
  return `Task`.
- `InvocationContext` construction is classified consistently with its documented
  Beta application API.
- Generic Agent invocation identity is removed: `InvocationContext` no longer
  exposes `thread_id` / `session_id`, Agent invocation APIs no longer accept
  `thread_id:`, and no replacement generic correlation identity is introduced.
- The canonical `JournalRecord` representation no longer contains
  `correlation_id`; legacy durable Hashes containing the removed key remain
  readable without an eager data rewrite.
- Tool approval notification/policy parent identity now uses canonical Agent
  `execution_id` instead of `agent_invocation_id`; new suspended-execution
  approval data uses the same parent identity.
- Legacy embedded suspended approval hashes remain readable by deriving the
  logical parent from their enclosing Agent execution; historical
  content-addressed audit bodies are not rewritten.
- Agent, Tool, and Multi-Agent concrete `FSMSession` instances no longer reuse
  domain/context IDs as EventLoop routing targets. Async callbacks use
  session-local event sinks, and Provider completion is routed to the owning
  FSMSession before EventLoop validates/applies `llm_call_id`-bound result
  state. Workflow retains its pre-load admission ordering through a private
  single-use FSMSession identity reservation; opaque Workflow admission
  ownership remains ACS-13 work.
- OutputParser `parse` is classified as the public subclass extension point that
  concrete parsers implement.

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
- `OffloadPool#submit` now returns the common caller-facing `Phronomy::Task`.
  OffloadPool queue/worker/timeout/abandonment state is held by a private
  Operation record rather than by a second completion-handle class.
- Submit cancellation now settles the caller-facing `Task` immediately.
  Cancellation before worker start prevents execution; cancellation after worker
  start marks the private Operation abandoned while allowing the synchronous
  worker to finish without asynchronous `Thread#raise`.
- Monotonic deadlines carried by an OffloadPool submit cancellation token are
  promoted by the Runtime timer queue, so cancellation completion does not
  require a polling Thread.
- Independent notification callbacks now isolate subscriber failures. An
  `StandardError` from one `CancellationToken#on_cancel` or `Task#on_complete`
  callback is logged and does not suppress later subscribers.
- `Task#wait_result(timeout:)` is the waiter-local synchronous timeout bridge.
  It does not settle or cancel the Task; operation-wide cancellation is
  represented by the CancellationToken supplied to the creating API.
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
- Caller-facing `OffloadPool::PendingOperation` and
  `PendingOperation#blocking_wait`; asynchronous Phronomy APIs use `Task` as the
  completion contract.
- Waiter-local `cancellation_token:` from `PendingOperation#blocking_wait`.
  Operation-wide cancellation remains on `OffloadPool#submit(cancellation_token:)`.


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
- Framework-owned short in-memory Tools (TeamCoordinator queue controls and
  SharedState store access) explicitly declare
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
  Journal -> Selection::Candidate -> Context Policy -> Manifest architecture.

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
