# Features and API stability

API means Application Programming Interface in this document.

Phronomy is pre-1.0. Minor releases may include breaking changes even to APIs
labelled Stable; patch releases should remain non-breaking. Consult
[`CHANGELOG.md`](../CHANGELOG.md) when upgrading.

- **Stable** — API is considered complete and suitable for production use.
- **Beta** — functionality is complete and tested, but signatures or behaviour may evolve in a minor release.
- **Experimental** — functionality may change without notice and is not recommended as a long-term compatibility boundary.

The `main` branch contains unreleased development work. Pin a released gem version
for production deployments.

## Core building blocks

| Feature | Stability |
|---|---|
| **Workflow** — Stateful, branching workflows with `wait_state` and explicit events | Stable |
| **Agent** — Stateful ReAct-style agents with stable `agent_id`, one mutable live owner per Runtime, persistence-backed execution state, canonical history, and conversation context | Stable |
| **Tool authoring façade** — `Phronomy::Tool::Base` is the public authoring name for the existing Capability base class; the legacy namespace remains compatible | Beta |
| **Unified Persistence** — One durable backend abstraction for Agent state and Workflow `workflow_states`; live Agent/Workflow state remains owned by Runtime/session authority between durable commits; custom backends implement the documented Backend SPI and repository/transaction semantics | Beta |
| **LLMAdapter SPI** — `Phronomy::LLMAdapter::Base#complete` / `#stream` define the Beta call-adapter extension boundary; Phronomy owns async/offload wrapping | Beta |
| **Before-Large-Language-Model (LLM) Input Hook** — Three-tier per-call LLM input customization via `before_llm_input` and `LLMInputPatch` | Stable |
| **Context Management** — Journal + Context Policy + per-LLM-call Manifest with token-budget-aware selection and protocol-safe Tool Call / Tool message dependencies | Stable |
| **Filters** — Input/output transformation and blocking via `Filter::Base` | Beta |
| **`PromptInjectionFilter`** — Built-in pattern-based prompt-injection filter | Beta |
| **Capability redaction/result-size controls** — `redact_params` and `max_result_size` | Beta |
| **Output Parser** — JSON and Struct-mapped parsers for structured LLM responses | Stable |
| **Tracing** — Pluggable span-based observability | Stable |
| **Error Taxonomy** — Provider errors translated to Phronomy transport/authentication/rate-limit/context errors | Beta |

Agent definition lineage is separate from Agent instance identity. A named
concrete Agent may declare `agent_definition version: N`; when `id:` is omitted,
its fully-qualified Ruby class name is the stable `agent_definition_id`.
Applications may keep a lineage independent of Ruby constant naming with an
explicit `id:`. Concrete subclasses declare their own definition revision
rather than implicitly inheriting the parent revision. The Stable
`before_llm_input` context exposes the semantic revision as
`agent_definition_version`.

## Knowledge and integration

| Feature | Stability |
|---|---|
| **Knowledge** — Journal-backed persistent Agent context registered with `knowledge:` / `add_knowledge`, selected per LLM call by Context Policy | Beta |
| **`VectorStore#size`** — Document count for InMemory, RedisSearch, and Pgvector backends | Beta |
| **VectorStore async convenience** — `add_async` / `search_async` / `remove_async` / `clear_async` offload the synchronous Backend SPI through Phronomy and return `Task`; native async override is not part of the current Backend SPI | Beta |
| **Embedding async convenience** — `embed_async` offloads synchronous `embed` through Phronomy and returns `Task` | Beta |
| **Model Context Protocol (MCP) Tool** — `Phronomy::Tools::Mcp` integration through the official `mcp` gem | Beta |
| **Agent Tool** — `Phronomy::Tools::Agent.from_agent` exposes a child Agent as a Tool without occupying a worker while waiting | Beta |
| **Vector Search Tool** — `Phronomy::Tools::VectorSearch` wraps VectorStore and Embeddings adapters | Beta |

## Execution and reliability

| Feature | Stability |
|---|---|
| **EventLoop** — Runtime-owned event-driven execution core shared by Agent, ToolInvocation, Workflow, and MultiAgent sessions; single writer for Phronomy-managed live Agent execution state | Beta |
| **Agent execution result authority** — Session-local routing plus current FSM state and purpose-specific semantic IDs (`llm_call_id`, `tool_invocation_id`) reject stale async results | Beta |
| **Agent live ownership/admission** — Runtime owns one mutable live Agent per `agent_id`; EventLoop rejects competing same-Agent top-level executions while suspension retains the logical execution slot; Persistence admission remains durable defense | Beta |
| **Workflow durable admission** — Same-process admission is keyed by durable `workflow_instance_id` from load through terminal save; admission-owner representation remains Runtime-internal and is reconciled separately | Beta |
| **`invoke` / `invoke_async`** — Blocking and non-blocking Agent/Workflow entry points | Stable |
| **Agent async events** — `invoke_async(..., on_event:)` and `stream_async(..., on_event:)`; streaming additionally emits `:token` | Beta |
| **`stream` / `stream_async`** — Event callbacks execute on EventLoop and must return quickly | Beta |
| **`stream_callback_error_policy`** — Terminal event callback error policy (`:report` / `:fail_task`) | Beta |
| **Task completion contract** — `Task` is the common caller-facing completion handle for EventLoop/FSMSession lifecycles and OffloadPool work | Beta |
| **`Task#map`** — Application-level Task result transformation and error propagation | Stable |
| **CancellationToken** — Cooperative cancellation with explicit `cancel!`, lazy monotonic deadlines, and callback registration | Experimental |
| **Tool `execution_mode`** — `:cooperative` for short EventLoop-safe work; `:offloaded` for synchronous work that must stay off EventLoop | Experimental |
| **OffloadPool sizing** — `offload_pool_size` / `offload_queue_size`; named pools available for application-owned isolation | Beta |
| **InvocationContext** — Explicit cancellation/deadline/policy/tracing context for Agent and Workflow invocations | Beta |
| **Metrics** — OffloadPool active/queue/abandoned metrics plus EventLoop queue/lag metrics | Beta |
| **Runtime lifecycle** — Runtime-owned EventLoop and terminal `Runtime#shutdown` | Beta |

## Agent and workflow patterns

| Feature | Stability |
|---|---|
| **Workflow asynchronous pattern** — Start async work, return immediately, and continue through `Workflow#signal` | Beta |
| **Semantic Multi-Agent Handoff** — `MultiAgent::Handoff` transfers active responsibility from an explicit Source Agent to a Target Agent, projects policy-bounded Context with provenance, keeps the Target active across user turns within the same Runtime/main-Agent lifetime, and does not claim durable continuation across Runtime reset | Beta |
| **GeneratorVerifier** — Generator-Verifier loop with injectable prompts/parsers | Beta |
| **`Phronomy::MultiAgent::Orchestrator`** — Parallel subagent dispatch, fan-out, and `subagent` DSL | Beta |
| **`Phronomy::MultiAgent::TeamCoordinator`** — LLM coordinator with stateful worker Agents | Beta |
| **SharedState** — Peer-agent shared-state coordination | Experimental |
| **Human-in-the-loop approval** — Suspension and approval/resume on the same process-local live Agent owner and AgentInvocation, with a fresh FSMSession incarnation on resume | Beta |
| **`tool_approval_policy`** — Application-defined allow/approve/reject policy using a value-only `ApprovalEvaluationRequest` without live Agent/Tool references | Beta |

For Handoff, Application `HandoffPolicy` controls what may cross the Source/Target
boundary. Transferred Handoff Context is immutable request-scoped material rather
than automatic Target Journal/Knowledge adoption. Target Context Policy still
selects what enters each individual Target LLM call.

## Public API boundary

The feature tables above describe the primary APIs intended for gem consumers.
Source declarations marked `@api private`, including most EventLoop/FSMSession and
OffloadPool internals, are implementation details and may change without the same
compatibility guarantees.

The YARD `@api` classification is independent from Ruby language visibility in
both directions. `@api public` marks a compatibility contract, but the Ruby
visibility still follows the intended calling model. `@api private` means
"internal/no compatibility promise" and does not require a Ruby `private`
declaration; some internal methods remain Ruby-public because Phronomy components
call them through explicit receivers.

`Task` is the caller-facing completion abstraction. Framework components own
settlement (`complete` / `fail` / `cancel!`); application code observes Tasks via
`wait_result`, `on_complete`, `map`, and state readers. Operation-wide cancellation
is requested through the `CancellationToken` accepted by the API that created the
Task.

Persistence Backend SPI methods, LLMAdapter methods, and other documented
extension contracts are deliberate exceptions to the ordinary
application-facing interpretation of `@api public`: they are compatibility
contracts for implementers. Extension implementations must not depend on Runtime
private execution objects such as EventLoop/FSMSession/OffloadPool operation
records or EventLoop Agent execution entries.

`Phronomy::StateStore` is no longer a public backend abstraction. Workflow
durability is provided through `Phronomy::Persistence#workflow_states`; see the
0.19 migration guide when upgrading code that used `state_store:`.

## Advanced and internal APIs

| Feature | Stability |
|---|---|
| **`Phronomy::Diagnostics`** — Snapshot of EventLoop lag/queue state and OffloadPool activity | Experimental |
| **`Phronomy::Testing::FakeClock`** — Test-only deterministic clock helper | Beta |
| **`Phronomy::Testing::PersistenceContract`** — Explicitly loaded RSpec conformance suite for custom Persistence backends | Beta |

`Phronomy::Testing::PersistenceContract` is available only after explicit
`require "phronomy/testing/persistence_contract"`. Ordinary
`require "phronomy"` and production eager-load do not load RSpec.

For runtime ownership and the distinction between public lifecycle APIs and
private execution machinery, see [Runtime and concurrency](runtime-and-concurrency.md).
