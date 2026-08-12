# Phronomy

> **⚠️ Development Notice**
> This project is primarily developed and maintained by **AI coding agents**.
> As a result, `main` receives frequent, large, and unannounced changes.
> External contributors should expect significant churn and potential conflicts at any time.
> We apologise for the instability this may cause.

**Phronomy** is a Ruby AI agent framework inspired by open-source AI agent frameworks.  
It provides composable building blocks — Workflows, Agents, Tools, Filters, and Tracing — all powered by [RubyLLM](https://github.com/crmne/ruby_llm) for LLM abstraction.

## Features

> **Stability labels** (phronomy is pre-1.0, so `0.x` minor releases may include
> breaking changes even to `Stable` APIs; patch releases (`0.x.y`) are non-breaking):
> - `Stable` — API is considered complete and suitable for production use. Breaking changes
>   within a minor release are avoided, and any breaking changes in a minor bump are noted
>   in `CHANGELOG.md`.
> - `Beta` — Functionality is complete and tested, but the API may change in a minor version release (0.x). Use with awareness that signatures or behaviour may evolve.
> - `Experimental` — Functionality may be incomplete or subject to breaking changes at any time without notice. Not recommended for production use.
>
> **Note**: The `main` branch contains unreleased development work. Pin to a released gem
> version (`gem "phronomy", "~> 0.x"`) for stability in production.

**Core building blocks**

| Feature | Stability |
|---|---|
| **Workflow** — Stateful, branching workflows with wait_state/send_event | Stable |
| **Agent** — Stateful ReAct-style tool-calling agents with stable `agent_id`, persistence-backed execution state, canonical execution history, guardrails, and conversation context | Stable |
| **Before-LLM-Input Hook** — Three-tier per-call LLM input customization via `before_llm_input` and `LLMInputPatch` | Stable |
| **Context Management** — Canonical Journal + per-LLM-call Manifest architecture with token-budget-aware selection and protocol-safe Tool Call / Tool message dependencies. Context selection never deletes canonical execution history | Stable |
| **Filters** — Input/output transformation and blocking via `Filter::Base`; call `block!(reason)` to reject and raise `FilterBlockError` | Beta |
| **`PromptInjectionFilter`** — Built-in `Filter::Base` subclass that detects prompt-injection patterns; usable standalone or as part of a filter chain | Beta |
| **`Agent::Context::Capability::Base.redact_params` / `.max_result_size`** — Class-level DSL: `redact_params` masks parameter values in log/trace output; `max_result_size` truncates oversized tool results before they reach the LLM | Beta |
| **Output Parser** — JSON and Struct-mapped parsers for structured LLM responses | Stable |
| **Tracing** — Pluggable span-based observability | Stable |
| **Error Taxonomy** — final RubyLLM/provider errors are translated to `RateLimitError`, `AuthenticationError`, `ContextLengthError`, and `TransportError` without replaying the Agent invocation | Beta |

**Knowledge and integration**

| Feature | Stability |
|---|---|
| **Knowledge** — Journal-backed persistent Agent context registered with `knowledge:` / `add_knowledge`; selected per LLM call by Context Policy; `clear_knowledge!` logically resets retained Knowledge without deleting Journal history | Beta |
| **`VectorStore#size`** — Returns document count for all three backends (InMemory, RedisSearch, Pgvector) | Beta |
| **`VectorStore::AsyncBackend` mixin** — Pluggable async interface for `VectorStore`; default pool-backed implementations for `search_async`, `add_async`, `remove_async`, `clear_async`; backends with native async drivers override individual methods to bypass `BlockingAdapterPool` entirely; all existing backends remain unchanged | Beta |
| **MCP Tool** — `Phronomy::Tools::Mcp`: Model Context Protocol server integration via the official `mcp` gem; `Phronomy::Tools::Agent`: wraps an agent class as a callable tool via `from_agent` | Beta |
| **Vector Search Tool** — `Phronomy::Tools::VectorSearch`: wraps a `VectorStore` and `Embeddings` adapter as a callable agent tool via `from_store` | Beta |

| **Execution and reliability** | |
|---|---|
| **EventLoop** — Runtime-owned event-driven execution core shared by all Agent invocations, Tool invocations, and Workflow sessions. Not configurable; EventLoop is always active when the Runtime is running. `Phronomy::EventLoop` itself is an internal API | Beta |
| **`invoke` / `invoke_async`** — `Agent::Base#invoke` blocks the calling thread and returns the final result Hash; `Agent::Base#invoke_async` returns a `Phronomy::Task` immediately without blocking; `Workflow#invoke` and `Workflow#invoke_async` follow the same contract | Stable |
| **Agent async events** — `invoke_async(..., on_event:)` and `stream_async(..., on_event:)` share `:tool_call`, `:tool_result`, `:approval_required`, `:done`, `:error`, `:timeout`, and `:cancelled`; streaming adds `:token` | Beta |
| **`stream` / `stream_async`** — callbacks execute on the EventLoop thread and must return quickly; the block form remains a compatibility alias for `on_event:` | Beta |
| **`stream_callback_error_policy`** — Backward-compatible setting shared by `invoke_async` and `stream_async` terminal `on_event:` callbacks: `:report` (default) preserves the Agent result, while `:fail_task` fails the returned Task with `Phronomy::StreamCallbackError`; Agent execution errors are never replaced by callback errors | Beta |
| **`invoke_async` / `call_async`** — `Agent::Base#invoke_async` and `Workflow#invoke_async` return a `Task`; `Agent::Context::Capability::Base#call_async` similarly; compatible with EventLoop and standalone contexts | Stable |
| **`Task#map`** — transforms a Task's completed value and propagates failure/cancellation. `Task#map` remains available for application-level Task composition, but Workflow entry and transition actions must not return a Task | Stable |
| **CancellationToken** — Cooperative cancellation via `cancel!`/`cancelled?`/`raise_if_cancelled!`; `timeout_after(seconds)` for monotonic-clock deadlines; passed as `config: { cancellation_token: token }` to agents and `dispatch_parallel`; injected into `tool.execute` when the method declares a `cancellation_token:` keyword; bridged to `MCP::Cancellation` in `Phronomy::Tools::Mcp#execute` | Experimental |
| **`execution_mode` DSL on `Agent::Context::Capability::Base`** — `:cooperative` means EventLoop-safe work that returns quickly; a specialized cooperative Tool may start another Phronomy async lifecycle and return a completion `Task` immediately. `:blocking_io` (default) is offloaded to `BlockingAdapterPool`. `:cpu_bound` and `:external_process` require dedicated executors and currently raise `ConfigurationError` | Experimental |
| **`blocking_io_pool_size` / `blocking_io_queue_size`** — Configure the default `BlockingAdapterPool` via `Phronomy.configure { \|c\| c.blocking_io_pool_size = 20; c.blocking_io_queue_size = 200 }`; all LLM calls, MCP tool calls, and other blocking I/O share this pool; defaults: `pool_size: 10`, `queue_size: 100` | Beta |
| **`invocation_context:` keyword on `Agent#invoke` / `Workflow#invoke`** — Pass a `Phronomy::InvocationContext` directly; `thread_id`, `cancellation_token`, and `deadline`-based timeout are derived from it; `task_id` / `parent_task_id` appear in trace spans automatically; `config:` keys remain supported as backward-compat aliases | Beta |
| **`Phronomy::Metrics`** — `Phronomy::Metrics.snapshot` reports the two concurrency boundaries: `blocking_pool_active`, `blocking_pool_queue_length`, `blocking_pool_abandoned_total`, `blocking_pool_size`, plus `event_loop_queue_depth`, `event_loop_queue_max_depth`, `event_loop_lag_last_ms`, `event_loop_lag_max_ms`, and `event_loop_lag_average_ms` | Beta |
| **`Phronomy.with_configuration` / `Phronomy.reset_runtime!`** — Scoped configuration override; `reset_runtime!` performs a full `Runtime#shutdown` (including EventLoop termination) then resets configuration; intended for test isolation | Beta |
| **`Runtime#event_loop`** — Returns the Runtime-owned `EventLoop` instance; lazy-initialised on first access; EventLoop lifetime is tied to the owning Runtime | Beta |
| **`Runtime#shutdown(timeout:, cancel_grace:)`** — Irreversible Runtime shutdown: drains active sessions, terminates the EventLoop dispatcher, then stops pools and timers; returns a `ShutdownResult` with `runtime_outcome` and `cleanup_status` fields | Beta |

**Agent patterns**

| Feature | Stability |
|---|---|
| **Workflow asynchronous pattern** — Entry/transition actions start async work, return immediately, then deliver completion through `Workflow#signal`; Phronomy does not provide a generic task-spawn primitive | Beta |
| **Multi-agent** — Agent-as-Tool pattern and hub-and-spoke handoff routing | Beta |
| **GeneratorVerifier** — Generator-Verifier loop with injectable prompt builders/parsers | Beta |
| **`Phronomy::MultiAgent::Orchestrator`** — Parallel subagent dispatch, fan-out, and `subagent` DSL | Beta |
| **`Phronomy::MultiAgent::TeamCoordinator`** — Agent teams pattern: LLM coordinator + stateful workers with sequential task assignment (worker-local message history persisted across tasks) | Beta |
| **Agent::SharedState** — Shared state pattern: peer agents collaborate via a shared KnowledgeStore; `member` DSL with per-agent instructions and `coordination` team protocol | Experimental |
| **Human-in-the-loop approval** — `Agent::Base#invoke` returns `{ suspended: true, execution_id: String, approval_request: Phronomy::Agent::ToolApprovalRequest }` when approval is required. `#approve` / `#approve_async` resume that execution. Suspended execution state is stored in Persistence, but durable activation rehydration after a process restart is not yet supported | Beta |
| **`tool_approval_policy`** — Instance-level callable that maps each `ToolApprovalRequest` to `:allow`, `:require_approval`, or `:reject`; set on the agent instance before invoking | Beta |
| **`Filter::Base` — unified value filter interface** — `Phronomy::Filter::Base` with a single abstract method `call(value, **context)`; apply to user input (`add_input_filter` / `input_filter` DSL), final LLM output (`add_output_filter` / `output_filter` DSL), or individual tool return values (`add_tool_result_filter(tool_class?, filter)` / `tool_result_filter` DSL); filters transform values and return the result, or raise `Phronomy::FilterBlockError` to reject; filter chains are composable; the same filter instance can be reused across all three sites | Beta |

> **Public API boundary**: The table above lists the primary public features
> intended for gem consumers. Every entry has an associated stability label.
> All other classes, modules, and methods — including everything in the
> [Advanced / Internal APIs](#advanced--internal-apis) section below — are
> marked `@api private` in source and may change without notice. Do not
> depend on internal APIs in application code.

## Advanced / Internal APIs

The APIs listed below are intended for advanced use cases, framework internals, and test infrastructure. Typical application code does not need to interact with them directly.

> These APIs are subject to change without the same backwards-compatibility guarantees as the stable public API.

| Feature | Stability |
|---|---|
| **`Phronomy::Diagnostics`** — Snapshot of EventLoop lag/queue state and BlockingAdapterPool activity; blocking synchronous APIs are rejected from EventLoop context with `EventLoopReentrancyError` | Experimental |
| **`Phronomy::Testing::FakeClock`** — Test-only deterministic clock helper. It does not replace the production Runtime or EventLoop | Beta |

## Installation

Add to your Gemfile:

```ruby
gem "phronomy"
```

Then run:

```bash
bundle install
```

### RubyLLM setup

Phronomy uses [RubyLLM](https://github.com/crmne/ruby_llm) for LLM access.
Configure your provider credentials before using agents or chains:

```ruby
RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  # c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]

  # RubyLLM owns LLM transport timeout and retry policy.
  c.request_timeout = 120
  c.max_retries = 3
  c.retry_interval = 0.1
  c.retry_backoff_factor = 2
  c.retry_interval_randomness = 0.5
end
```

See the [RubyLLM documentation](https://rubyllm.com) for all supported providers. Phronomy does not add another LLM timeout or retry layer.

### Execution-policy migration for 0.15

| Removed Phronomy setting | Replacement |
|---|---|
| `retry_policy` | RubyLLM transport retry, or explicit application orchestration |
| `invoke_timeout` | `InvocationContext#deadline` or `cancellation_token` when the caller needs a root deadline |
| `config[:llm_timeout]` | `RubyLLM.configure { |c| c.request_timeout = ... }` |
| Tool `retry_on` | Tool/client-specific retry with explicit idempotency guarantees |
| `config[:tool_timeout]` | Tool/client-native timeout |
| `max_parallel_tools` | No replacement; `parallel_tool_execution` remains an on/off mode |
| `InvocationContext#provider_limits` | Configure the provider client directly |
| `stream_queue_max_size` | No replacement; the shared EventLoop queue is unbounded by design. Monitor `Metrics.snapshot[:event_loop_queue_depth]` instead |

### 0.16 cleanup migration

The following compatibility-only APIs have been removed from the active contract:

| Removed API | Current contract |
|---|---|
| `context_overhead` | Manifest-first assembly budgets actual mandatory + selected content |
| Tool `on_error :return_empty` | Use `:raise` or `:suppress` |
| `dispatch_parallel(..., force_kill:)` / `fan_out(..., force_kill:)` | Cooperative cancellation; no force-kill switch |
| `runtime_backend` | Removed. Phronomy has one execution model: EventLoop/FSMSession for lifecycle coordination and BlockingAdapterPool for unavoidable blocking I/O |
| `Runtime.instance = ...` | Runtime replacement is test/internal infrastructure, not a public setter |
| `Runtime#spawn` / `TaskGroup` | Removed. Start framework async work through its domain async API (`invoke_async`, Workflow events, ToolInvocation, FanOut) |
| `tools ToolA, ToolB` | Use `tools(ToolA => nil, ToolB => nil)` |
| `CancellationToken.new(deadline: Time...)` | Use `CancellationToken.timeout_after(seconds)` for token deadlines |
| `StaticKnowledge` / `EntityKnowledge` / `Knowledge::Base` / `Phronomy::KnowledgeSource` | Register plain persistent Knowledge with `knowledge:` or `add_knowledge` |
| `static_knowledge*` class APIs | Persistent Knowledge belongs to Agent instances and is Journal-backed |
| `clear_memory!` | Use `clear_knowledge!`; conversation history is controlled independently with `clear_transcript!` |

The legacy `build_context` / `LlmContextWindow::Assembler` extension path is no
longer an active API. Stateful Agent input is assembled through the canonical
Journal → Context Policy → LLM Input Manifest pipeline.

### Optional dependencies

Install additional gems only for the features you use:

| Gem | Required for |
|-----|-------------|
| `pgvector` | `Phronomy::VectorStore::Pgvector` |
| `redis` | `Phronomy::VectorStore::RedisSearch` |
| `opentelemetry-api` | `Phronomy::Tracing::OpenTelemetryTracer` |

## Quick Start

### Agent — ReAct tool-calling agent

```ruby runnable
class WebSearch < Phronomy::Agent::Context::Capability::Base
  description "Search the web"
  param :query, type: :string, desc: "Search query"

  def execute(query:)
    # Replace with a real search API call (e.g., SerpAPI, Tavily)
    "Mock search result for: #{query}"
  end
end

class ResearchAgent < Phronomy::Agent::Base
  agent_definition id: "research-agent", version: 1
  model "gpt-4o"
  instructions "You are a research assistant. Use tools to answer questions."
  tools(WebSearch => nil)
  max_iterations 5
end

result = ResearchAgent.new.invoke("What happened in AI research this week?")
puts result[:output]
```

#### Streaming

`stream` blocks the calling thread while delivering events; `stream_async` returns a `Task`
immediately. Callbacks always execute on the **EventLoop thread** — keep them lightweight and
do not call blocking I/O or synchronous Agent APIs inside a callback.

```ruby
# Synchronous streaming — blocks until done
result = ResearchAgent.new.stream("What happened in AI research this week?") do |event|
  case event.type
  when :token           then print event.payload[:content]
  when :tool_call       then puts "\n[Calling: #{event.payload[:tool_call].name}]"
  when :tool_result     then puts "[Tool done]"
  when :done            then puts "\n---"
  when :approval_required
    # Approval needed — handle via approve_async (see Human-in-the-loop section)
  when :error           then warn "Error: #{event.payload[:error].message}"
  end
end
puts result[:output]

# Non-blocking streaming — returns Task immediately
task = ResearchAgent.new.stream_async("Summarise AI news") do |event|
  broadcast_to_websocket(event) if event.type == :token   # must return quickly
end
result = task.wait_result
```

#### Human-in-the-loop approval

When a tool is configured with `requires_approval true` and no `:allow` policy is set,
`invoke` suspends and returns `{ suspended: true, agent_invocation_id:, approval_request: }`.
Resume via `approve` (synchronous) or `approve_async` (non-blocking, safe inside callbacks):

```ruby
agent = ResearchAgent.new
agent.tool_approval_policy { :require_approval }

result = agent.invoke("Run the search")
if result[:suspended]
  request = result[:approval_request]
  puts "Tool: #{request.items.first.tool_name}"

  # From top-level code — synchronous
  final = agent.approve(
    result[:agent_invocation_id],
    approval_request_id: request.id,
    approved: true
  )
  puts final[:output]
end

# Inside a stream callback — use approve_async to avoid EventLoop re-entry
agent.stream_async("Run it") do |event|
  if event.type == :approval_required
    req = event.payload[:request]
    approve_task = agent.approve_async(
      req.agent_invocation_id,
      approval_request_id: req.id,
      approved: true
    )
    # approve_task resolves when the resumed invocation completes
  end
end
```

> **Important**: Approval state is stored in-process (`AgentInvocationRegistry`). It is **not**
> persisted across process restarts and is **not** shared between pods or processes.

### Workflow — Stateful workflow with wait_state/send_event

```ruby runnable
class ReviewContext
  include Phronomy::WorkflowContext
  field :draft,    type: :replace
  field :feedback, type: :replace
  field :approved, type: :replace, default: false
end

# Placeholder callables representing your own implementation
write_draft  = ->(state) { state.merge(draft:    "Draft content here") }
review_draft = ->(state) { state.merge(feedback: "Feedback on: #{state.draft}") }

app = Phronomy::Workflow.define(ReviewContext) do
  initial :write
  state     :write,    action: write_draft
  state     :review,   action: review_draft
  wait_state :awaiting_approval           # halts here for human decision
  state     :finalize, action: ->(s) { s.merge(approved: true) }
  transition from: :write,              to: :review
  transition from: :review,             to: :awaiting_approval
  transition from: :finalize,           to: :__finish__
  transition from: :awaiting_approval,  on: :approve, to: :finalize
  transition from: :awaiting_approval,  on: :reject,  to: :write
end

# First run — halts at :awaiting_approval
state = app.invoke({ draft: "" }, config: { thread_id: "doc-1" })
puts "Halted: #{state.halted?}"   # => true
puts "Draft: #{state.draft}"

# Resume after human approval — pass the halted state and the event name
final = app.send_event(state: state, event: :approve)
puts "Approved: #{final.approved}"  # => true
```

Start the Agent as an asynchronous activity of the active state, then
map its lifecycle event to an application-defined Workflow event:

```ruby
class TranslationContext
  include Phronomy::WorkflowContext

  field :query
  field :answer
  field :error

  def handle_fsm_event(event)
    case event.type
    when :translation_completed
      self.answer = event.payload[:answer]
    when :translation_failed
      self.error = event.payload[:error]
    end
    false
  end
end

workflow = nil

workflow = Phronomy::Workflow.define(TranslationContext) do
  initial :translate

  state :translate, action: ->(ctx) {
    TranslationAgent.new.invoke_async(
      ctx.query,
      on_event: ->(event) {
        case event.type
        when :done
          workflow.signal(
            thread_id: ctx.thread_id,
            event: :translation_completed,
            payload: {answer: event.payload[:output]}
          )
        when :error, :timeout, :cancelled
          workflow.signal(
            thread_id: ctx.thread_id,
            event: :translation_failed,
            payload: {error: event.payload[:error]}
          )
        end
      }
    )
    ctx
  }

  state :done
  state :failed

  transition from: :translate, on: :translation_completed, to: :done
  transition from: :translate, on: :translation_failed, to: :failed
end
```

The application owns payload interpretation, correlation, and field updates.
Phronomy does not automatically copy Agent results into WorkflowContext.

Transitions may define an `action:` callback in addition to a `guard:`:

```ruby
transition(
  from: :review,
  on: :approved,
  to: :publish,
  guard: ->(context, event) {
    event.payload[:request_id] == context.request_id
  },
  action: ->(context, event) {
    context.merge(approved_by: event.payload[:reviewer])
  }
)
```

The callback order for a successful transition is:

```text
source exit callbacks
-> selected transition action
-> target entry callbacks
```

Transition actions may accept either `(context)` or `(context, event)`. A
returned Workflow context replaces the current context before target entry
callbacks run. Returning `nil` or another non-context value preserves the
current context.

Like entry actions, transition actions are synchronous Run-to-Completion
callbacks. They may start asynchronous work and register a listener that later
calls `Workflow#signal`, but they must return the context or `nil` immediately.
Returning `Phronomy::Task` raises
`Phronomy::InvalidAsyncTransitionActionError`; Phronomy does not implicitly
await it.

For a transition with `on:`, the two-argument action receives the external
`Phronomy::Event`. For an automatic transition without `on:`, it receives the
internal event:

```text
event.type    == :state_completed
event.payload == nil
```

When several transitions have the same source and event, guards are evaluated
in declaration order. The first matching transition is selected, and only that
transition's action runs.

### Multi-Agent — Agent-as-Tool pattern

Use `Phronomy::Tools::Agent.from_agent` (or `MultiAgent::Orchestrator.subagent`)
rather than calling a synchronous child Agent from `Tool#execute`.

```ruby
class ResearchAgent < Phronomy::Agent::Base
  agent_definition id: "research-agent", version: 1
  model "gpt-4o"
  instructions "Research the requested topic."
end

ResearchTool = Phronomy::Tools::Agent.from_agent(
  ResearchAgent,
  tool_name: "research",
  description: "Delegate research to the research Agent"
)

class OrchestratorAgent < Phronomy::Agent::Base
  agent_definition id: "orchestrator-agent", version: 1
  model "gpt-4o"
  instructions "Use the research Tool when research is required."
  tools(ResearchTool => nil)
end
```

Agent-backed Tools are asynchronous internally. The parent ToolInvocation starts
the child Agent and returns to EventLoop immediately; it does **not** occupy a
BlockingAdapterPool worker while waiting for the child. The child Agent's actual
blocking provider I/O still uses the bounded BlockingAdapterPool.

### Filters — Input/output transformation and blocking

Filters sit between user input and the LLM (input filters) or between the LLM response and the caller (output filters).
A filter may **transform** the value (return the modified value) or **block** it (call `block!(reason)`, which raises `Phronomy::FilterBlockError`).

```ruby
class NoCreditCardFilter < Phronomy::Filter::Base
  def call(value, **_context)
    block!("Credit card numbers are not allowed") if value.match?(/\d{4}-\d{4}-\d{4}-\d{4}/)
    value
  end
end

agent = ResearchAgent.new
agent.add_input_filter(NoCreditCardFilter.new)

begin
  agent.invoke("Charge 4111-1111-1111-1111")
rescue Phronomy::FilterBlockError => e
  puts e.message   # => "Credit card numbers are not allowed"
end
```

> **Note:** Phronomy includes `PromptInjectionFilter`, a built-in pattern-based
> input filter that detects common injection patterns (see the feature table above).
> PII scanning and content classification are **not** provided by the framework;
> that logic must be implemented by the application. Reference implementations for
> common patterns are available in `phronomy-examples` (example 06).

### Knowledge — Persistent Agent context

Knowledge is plain logical content retained by one Agent and considered by
Context Policy for future LLM calls. It is not a separate source-object type and
it is not automatically mandatory.

Register initial Knowledge when creating the Agent:

```ruby
policy_text = File.read("policy.md")

agent = ResearchAgent.new(
  knowledge: [
    policy_text,
    "Customer tier: enterprise"
  ]
)
```

Add durable Knowledge later:

```ruby
agent.add_knowledge(
  "Customer locale: ja-JP",
  metadata: {"origin" => "customer_profile"}
)
```

Persistent Knowledge is Journal-backed, survives `Agent.load`, and is excluded
from the public conversation transcript. `clear_knowledge!` logically
invalidates earlier Knowledge while keeping the append-only Journal intact.

```ruby
agent.clear_knowledge!
```

For request-scoped retrieval results that should not be persisted, use
`before_llm_input` `segment_candidates` instead.

Load and split documents with built-in loaders when the application needs an
acquisition/RAG pipeline:

```ruby
chunks = Phronomy::VectorStore::Loader::MarkdownLoader.new.load("docs/guide.md")
         .then { |docs| Phronomy::VectorStore::Splitter::RecursiveSplitter.new(chunk_size: 512).split(docs) }
```

The application decides whether retrieved/extracted information becomes durable
Agent Knowledge (`add_knowledge`) or per-call Context (`before_llm_input`).

### Multi-Agent Handoff — Hub-and-spoke routing

```ruby
triage  = TriageAgent.new
billing = BillingAgent.new
support = SupportAgent.new

runner = Phronomy::Agent::Runner.new(
  agents: [triage, billing, support],
  routes: { triage => [billing, support] }
)

result = runner.invoke("I need help with my invoice")
puts result[:output]           # final answer
puts result[:agent].class      # => BillingAgent
```

### Before-LLM-Input Hook — Per-call LLM input customization

`before_llm_input` runs before every LLM call and allows an application to
customize that call without mutating the Agent, RubyLLM chat, or canonical
Journal state directly.

Hooks can be configured at three levels:

1. global — applies to every Agent
2. class — applies to every instance of one Agent definition
3. instance — applies only to one Agent instance

They run in that order: global → class → instance.

A hook receives an immutable `Phronomy::Agent::LLMInputBuildContext` containing
metadata about the LLM call:

- `agent_id`
- `agent_definition_id`
- `definition_version`
- `config`
- `call_sequence`

The hook does not receive the mutable Agent instance, RubyLLM messages, or
`RubyLLM::Chat`.

Return either:

- `nil` to leave the call unchanged, or
- a `Phronomy::Agent::LLMInputPatch`

### Class-level hook

```ruby
class MyAgent < Phronomy::Agent::Base
  agent_definition id: "my-agent", version: 1

  model "gpt-4o"

  before_llm_input ->(ctx) {
    Phronomy::Agent::LLMInputPatch.new(
      model_config_patch: {
        temperature: ctx.config[:precise] ? 0.0 : 0.7
      }
    )
  }
end
```

### Instance-level hook

```ruby
agent = MyAgent.new

agent.before_llm_input = ->(_ctx) {
  Phronomy::Agent::LLMInputPatch.new(
    model_config_patch: {
      max_output_tokens: 512
    }
  )
}
```

### Global hook

```ruby
Phronomy.configure do |config|
  config.before_llm_input = ->(_ctx) {
    Phronomy::Agent::LLMInputPatch.new(
      model_config_patch: {
        temperature: 0.3
      }
    )
  }
end
```

When multiple hooks provide `model_config_patch`, patches are merged in hook
order and later values win on key conflicts.

`LLMInputPatch` can also supply `segment_candidates` for additional per-call
context. Those candidates enter the same Context Policy selection path as
persistent/history candidates and are not automatically mandatory. They are
not persisted to the Journal.

```ruby
Phronomy::Agent::LLMInputPatch.new(
  segment_candidates: [
    {
      content: "The customer is on the enterprise plan.",
      category: :knowledge,
      role: :user
    }
  ]
)
```

The Journal remains the canonical record of observed execution history and
persistent Knowledge. `before_llm_input` customizes only the logical candidate
set for a particular LLM call.

### GeneratorVerifier — Generator-Verifier loop with custom prompt builders

```ruby
pipeline = Phronomy::GeneratorVerifier.new(
  draft_agent:  PolicyDraftAgent,
  review_agent: PolicyReviewAgent,

  # Full control over the LLM dialogue — supply your own prompts.
  draft_prompt_builder: ->(input, feedback) {
    base = "Answer precisely: #{input}"
    feedback ? "#{base}\n\nPrevious feedback: #{feedback}" : base
  },
  review_prompt_builder: ->(input, draft, citations) {
    "Is this draft accurate? Draft: #{draft}"
  },

  confidence_threshold: 0.7,
  max_iterations:       3,
  raise_if_untrusted:   false   # set true to raise LowConfidenceError
)

result = pipeline.invoke("What is the refund policy?")
puts result.output      # final answer
puts result.trusted?    # true when confidence >= 0.7
puts result.confidence  # Float 0.0–1.0
result.citations.each { |c| puts "#{c[:source]}: #{c[:excerpt]}" }
```

Optionally inject a custom result parser to decode non-JSON LLM output:

```ruby
pipeline = Phronomy::GeneratorVerifier.new(
  # ... (required params as shown above)
  draft_result_parser:  ->(text) { my_custom_draft_parser(text) },
  review_result_parser: ->(text) { my_custom_review_parser(text) }
)
```

Raise on low confidence:

```ruby
begin
  result = pipeline.invoke("question")
rescue Phronomy::LowConfidenceError => e
  puts "Untrusted (confidence #{e.result.confidence}): #{e.result.output}"
end
```

### MultiAgent::Orchestrator — Parallel subagent dispatch

> **Note:** Use `max_concurrency:` to cap concurrent workers and `on_error:`
> to control failure handling (`:raise` re-raises the first error after all
> tasks complete; `:skip` fills failed slots with `nil`). For very large
> fan-outs consider additional rate-limiting at the application level.

```ruby
class ResearchOrchestrator < Phronomy::MultiAgent::Orchestrator
  model "gpt-4o"
  instructions "Coordinate research tasks by dispatching to specialised agents."

  # Each subagent is automatically exposed as an LLM-callable tool.
  subagent :searcher,   SearchAgent
  subagent :summarizer, SummaryAgent, on_error: :skip
end

result = ResearchOrchestrator.new.invoke("Research the latest AI news.")
```

Programmatic parallel dispatch (no LLM loop):

```ruby
class MyOrchestrator < Phronomy::MultiAgent::Orchestrator
  model "gpt-4o"
  instructions "Orchestrate."

  def run(query)
    results = dispatch_parallel(
      {agent: SearchAgent,   input: "topic A"},
      {agent: AnalysisAgent, input: query},
      max_concurrency: 4,
      on_error: :skip,
      timeout: 30
    )

    translations = fan_out(
      agent: TranslationAgent,
      inputs: %w[Hello World],
      max_concurrency: 2,
      timeout: 20
    )

    results.compact.map { |r| r[:output] }.join("\n")
  end
end
```

### Workflow asynchronous pattern

Workflow entry/transition actions are Run-to-Completion callbacks. Start
asynchronous work, attach a completion listener, return the Workflow context
immediately, and deliver the result as a later `Workflow#signal` event. Do not
block a Workflow action waiting for a child Task.

For parallel child Agents, start each with `invoke_async`, count completions in
application state, and signal the Workflow when the required completion
condition is reached. For MultiAgent fan-out, prefer
`MultiAgent::Orchestrator#dispatch_parallel_async`, whose FanOut FSMSession
already implements bounded child concurrency.

### Output Parser — Structured LLM responses

```ruby
parser = Phronomy::OutputParser::JsonParser.new
data   = parser.parse('```json\n{"name":"Alice","score":0.9}\n```')
# => { name: "Alice", score: 0.9 }

PersonSchema = Struct.new(:name, :age, keyword_init: true)
parser = Phronomy::OutputParser::StructuredParser.new(PersonSchema)
person = parser.parse('{"name":"Alice","age":30}')
# => #<struct PersonSchema name="Alice", age=30>
```

### Tracing — Custom observability

```ruby
Phronomy.configure do |c|
  c.tracer = MyCustomTracer.new
end
```

### MCP Tool — External tool servers

> **MCP 1.x required.** Phronomy targets `mcp ~> 1.0`. For supported JSON Schema
> constructs, error semantics, and client lifecycle contracts, see
> [`docs/mcp-client.md`](docs/mcp-client.md).

```ruby
search_tool = Phronomy::Tools::Mcp.from_server(
  "stdio://./mcp-server",
  tool_name: "web_search"
)
```

Call `close` when the tool is no longer needed to shut down the underlying
child process (stdio transport) or release the HTTP connection:

```ruby
search_tool.close
```

### Agent State and Conversation History

Phronomy Agents are stateful objects. Each Agent has a stable `agent_id`, a persistent Agent root, an append-only execution Journal, and zero or more Agent executions.

Every concrete Agent definition must declare a stable definition identity:

```ruby
class ResearchAgent < Phronomy::Agent::Base
  agent_definition id: "research-agent", version: 1

  model "gpt-4o"
  instructions "You are a research assistant."
end
```

The definition ID identifies the application-level Agent definition. The version is checked when a previously persisted Agent is loaded so that persisted state is not silently interpreted by an incompatible Agent definition.

Create and continue using the same Agent instance normally:

```ruby
persistence = Phronomy::Persistence::InMemory.new

agent = ResearchAgent.create(
  agent_id: "research-session-42",
  knowledge: ["Customer tier: enterprise"],
  persistence: persistence
)

agent.invoke("My name is Alice.")
agent.add_knowledge("Customer locale: ja-JP")
result = agent.invoke("What is my name?")

puts result[:output]
```

Conversation history does not need to be passed back through `messages:` on every invocation. The Agent's canonical history is retained in its Journal and selected automatically when later LLM Calls are assembled.

A persisted Agent can be loaded again when the same Persistence backend is available:

```ruby
agent = ResearchAgent.load(
  "research-session-42",
  persistence: persistence
)

result = agent.invoke("Continue our previous discussion.")
```

`result[:messages]` remains available as a materialized transcript of the Agent's current conversation history. It is a projection of canonical Agent state, not the authoritative storage mechanism and does not need to be supplied to the next `invoke`.

Existing external conversation history can be supplied when a new Agent is created:

```ruby
agent = ResearchAgent.create(
  context: existing_messages,
  knowledge: initial_knowledge,
  persistence: persistence
)
```

Imported history must satisfy Phronomy's Import contract. User, assistant, and Tool messages are journaled without destroying their logical message boundaries. System instructions are Agent configuration and are not imported as ordinary conversation messages.

`thread_id` is an execution correlation identifier. It does not identify the persistent Agent and is not a substitute for `agent_id`.

The active conversation and Knowledge views can be advanced independently without deleting the canonical Journal:

```ruby
agent.clear_transcript!  # conversation only
agent.clear_knowledge!   # persistent Knowledge only
agent.reset_context!     # both
```

`purge!` is different: it permanently removes the Agent and its persisted execution history from the configured Persistence backend.

## Configuration

```ruby
Phronomy.configure do |c|
  c.default_model                   = "gpt-4o-mini"
  c.recursion_limit                 = 25
  c.tracer                          = Phronomy::Tracing::NullTracer.new
  c.before_llm_input                = nil   # optional global before_llm_input hook
  c.trace_pii                       = false # default; set to true only when trace data contains no PII
  c.logger                          = nil   # optional; any object responding to #warn (e.g. Rails.logger)
  c.event_loop_stop_grace_seconds   = 5     # seconds to wait for sessions to drain on shutdown
  c.stream_callback_error_policy    = :report   # :report (default) preserves Agent result; :fail_task fails Task with StreamCallbackError
end
```

`c.logger` receives framework diagnostic messages (e.g. unreachable-state warnings from
`Workflow.define`, stream callback errors, EventLoop queue backlog warnings). When `nil`
(default), messages are written to `$stderr` via `Kernel#warn`.

> **Note**: When `trace_pii = false`, both the _input_ and the _output_ (LLM
> responses and tool results) are replaced with `[REDACTED]` in trace spans.
> The default is `false` (PII protection enabled). Set to `true` only when
> trace data does not contain sensitive information.

## Sync vs Async API

Phronomy provides both synchronous and asynchronous invocation APIs.
Understanding when to use each prevents EventLoop stalls and hidden deadlocks.

| Context | Recommended API |
|---------|----------------|
| Top-level application code, Rails controller, background job | `agent.invoke(input)` — blocks the calling thread until done |
| Workflow action | Start `invoke_async` and use `Workflow#signal` in the `on_event:` callback to deliver the result as a later Workflow event |
| Top-level code that wants explicit async | `agent.invoke_async(input).wait_result` — blocks the calling thread until the Task completes |
| Streaming from top-level code | `agent.stream(input) { |event| ... }` — blocks until done; callbacks run on the EventLoop thread |
| Streaming non-blocking | `task = agent.stream_async(input) { |event| ... }` — returns Task immediately; callbacks run on the EventLoop thread |
| Resume approval from top-level code | `agent.approve(id, approval_request_id: r_id, approved: true)` — synchronous; blocks until resumed |
| Resume approval from an EventLoop callback | `agent.approve_async(id, approval_request_id: r_id, approved: true)` — returns Task; safe to call from a stream callback |

### Why this matters

`invoke` is a synchronous wrapper around asynchronous Agent execution and blocks
the calling thread until the Agent finishes. It is appropriate for top-level
application code such as CLI commands, controller actions, or background jobs.

Workflow entry and transition actions have a different contract: they are
synchronous Run-to-Completion callbacks and must finish promptly.

If a Workflow action needs an Agent or another asynchronous operation, start the
operation asynchronously, register its completion listener, return the Workflow
context, and use `Workflow#signal` to deliver completion as a later Workflow
event.

Do not call blocking `Agent#invoke` from an EventLoop callback, and do not return
the `Task` from `Agent#invoke_async` as the result of a Workflow entry or
transition action.

### EventLoop re-entry guard

Blocking synchronous APIs automatically reject EventLoop re-entry with
`Phronomy::EventLoopReentrancyError`. There is no runtime-backend or guard-mode
configuration switch.

Internal/framework code can query the current context with:

```ruby
Phronomy::Runtime.in_event_loop_context?
```

### Migration: blocking wait → Task mapping

```ruby
result = my_agent.invoke("Hello")
result = my_agent.invoke_async("Hello").wait_result
```

### Async work inside a Workflow

Workflow entry and transition actions are synchronous Run-to-Completion
callbacks.

They may start asynchronous work, but they must return the Workflow context (or
`nil`). Returning a `Phronomy::Task` from an entry or transition action is an
error.

When an asynchronous Agent finishes, deliver its result back to the live
Workflow as a later event with `Workflow#signal`.

```ruby
class AnswerContext
  include Phronomy::WorkflowContext

  field :question, type: :replace, default: ""
  field :answer,   type: :replace, default: nil
end

workflow = nil

workflow = Phronomy::Workflow.define(AnswerContext) do
  initial :asking

  state :asking
  state :done

  entry :asking, ->(ctx) {
    thread_id = ctx.thread_id

    my_agent.invoke_async(
      ctx.question,
      on_event: ->(event) {
        next unless event.type == :done

        workflow.signal(
          thread_id: thread_id,
          event: :answer_ready,
          payload: { answer: event.payload[:output] }
        )
      }
    )

    ctx
  }

  transition(
    from: :asking,
    on: :answer_ready,
    to: :done,
    action: ->(ctx, event) {
      ctx.merge(answer: event.payload[:answer])
    }
  )

  transition from: :done, to: :__finish__
end
```

The important separation is:

```text
Workflow action
    │
    ├─ starts asynchronous work
    │
    └─ returns context immediately
             │
             ▼
       asynchronous Agent
             │
             ▼
      on_event / callback
             │
             ▼
       Workflow#signal
             │
             ▼
      later Workflow event
```

`Task#map` remains a valid Task API for transforming Task results, but a mapped
Task must not be returned from a Workflow entry or transition action.

## Context Management

Phronomy uses a Manifest-first context architecture for stateful Agents.

```text
Canonical Journal
      ↓
Context candidates
      ↓
Context Policy
      ↓
LLM Call Manifest
      ↓
Runtime Projection
      ↓
RubyLLM / Provider
```

The **Journal** is the canonical append-only record of logical execution facts
observed by Phronomy and persistent Knowledge explicitly registered by the
application.

The **Manifest** is the canonical logical input fixed for one particular LLM
Call.

Context-window management therefore does not trim or rewrite the Agent's
canonical history. Phronomy selects the subset of available optional Context
needed for each LLM Call and records that selection in the Manifest.

Persistent Knowledge is an ordinary `:knowledge` Context candidate. It is not
concatenated into the mandatory system prompt. Conversation history and
Knowledge share the same policy/budget selection path while remaining distinct
in public transcript semantics.

Per-call `before_llm_input` segment candidates also pass through Context Policy
and are not written to the Journal.

Tool protocol dependencies are preserved during selection. An assistant message
containing Tool Calls and the corresponding Tool-role messages are selected as
a protocol-safe unit rather than independently pruning messages in a way that
would create an invalid LLM conversation.

When the available budget is insufficient, optional history or Knowledge can be
omitted from the current Manifest. Required context is never silently removed
merely to satisfy the budget. If required input cannot fit, Phronomy raises
`ContextBudgetExceededError`.

### Context-window configuration

Phronomy derives the effective context budget from RubyLLM model metadata when available.

For local or otherwise unregistered models, the context window can be declared explicitly:

```ruby
class LocalAgent < Phronomy::Agent::Base
  agent_definition id: "local-agent", version: 1

  model "local-model"
  context_window 32_768
  max_output_tokens 4_096
end
```

`context_window` determines the model's total context capacity.

`max_output_tokens` reserves capacity for the model's output.

Mandatory instructions, current input and Tool definitions are budgeted from
their actual canonical values. `context_overhead` is not part of the current
contract.

The current default Context Policy is framework-managed. Public custom Context
Policy APIs, deterministic persistent compaction, and other advanced policy
extension points are still evolving and should not yet be treated as stable
application APIs.

> **Note on CJK languages**: The default `TokenEstimator` uses a character-ratio heuristic
> calibrated for ASCII/Latin text (4 chars/token). For Chinese, Japanese, and Korean text,
> actual token counts are approximately **4× higher** than the estimate because CJK
> characters are typically 1 token each. For accurate CJK token counting, supply a
> tokenizer-backed callable:
>
> ```ruby
> require "tiktoken_ruby"
> enc = Tiktoken.encoding_for_model("gpt-4o")
> Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { enc.encode(text).length }
> ```

### CancellationToken — Cooperative cancellation

Pass a `CancellationToken` to any agent via `config: { cancellation_token: token }`.
Cancellation is checked at multiple granular checkpoints: before the LLM call,
after each streaming chunk, before each parallel tool-call batch, and after each
`before_llm_input` hook. `CancellationError` is raised immediately. Phronomy
does not replay the complete Agent invocation. No threads are force-killed —
`ensure` blocks always execute.

> **Cooperative cancellation — not preemptive**
>
> Phronomy uses _cooperative boundary cancellation_. The token is polled at the
> checkpoints listed above; it is **not** injected as a signal into a running
> operation. This means the following are **not** interrupted mid-execution:
>
> - An application retrieval/load operation that is already blocking
> - A single `chat.ask` call that is not streaming
> - A single `tool.execute` call that is already running
> - Any external I/O (database query, vector search, HTTP request) inside those calls
>
> For deep in-flight safety, complement `CancellationToken` with operation-native
> timeouts. Prefer library-native timeouts such as `Net::HTTP#read_timeout`,
> database `statement_timeout`, or Redis client timeout.

> **`timeout_after` vs `CancellationScope.deadline_in`**
>
> `CancellationToken.timeout_after(seconds)` uses lazy clock comparison: `cancelled?`
> returns `true` once the deadline elapses, but `on_cancel` callbacks are **not**
> fired. Bridges that rely on `on_cancel` — such as the `MCP::Cancellation` bridge
> in `Phronomy::Tools::Mcp#execute` — will therefore **not** be triggered on expiry.
>
> When you need the cancellation to propagate into in-flight I/O (e.g. an MCP
> `call_tool` request), use `CancellationScope` instead:
>
> ```ruby
> scope = Phronomy::Concurrency::CancellationScope.new.deadline_in(30)
> result = MyAgent.new.invoke("...", config: { cancellation_token: scope.token })
> ```
>
> `CancellationScope#deadline_in` registers a timer in the Runtime timer queue,
> which calls `cancel!` on expiry and fires all `on_cancel` callbacks — including
> the MCP bridge.

> **Transport timeout and retry ownership**
>
> Phronomy does not interpret `config[:llm_timeout]`, `config[:tool_timeout]`,
> Agent `retry_policy`, or Tool `retry_on`. Configure LLM transport behavior on
> RubyLLM (or another adapter) and configure Tool transport behavior on the Tool's
> HTTP/DB/MCP client.
>
> `InvocationContext#deadline` and `cancellation_token` remain available for a
> caller-defined root-operation boundary. They provide cooperative cancellation
> across the Phronomy execution tree; they do not replace provider-native socket,
> request, statement, or session timeouts.

```ruby
token = Phronomy::Concurrency::CancellationToken.timeout_after(30)
result = MyAgent.new.invoke("...", config: { cancellation_token: token })

token = Phronomy::Concurrency::CancellationToken.timeout_after(10)

orchestrator.dispatch_parallel(
  {agent: SearchAgent,   input: "topic A"},
  {agent: AnalysisAgent, input: "topic B"},
  cancellation_token: token
)
```

## Examples

Runnable examples covering all major features are available in the
[phronomy-examples](https://github.com/Raizo-TCS/phronomy-examples) repository.

Each example lives in its own numbered directory and can be run with:

```bash
bundle exec ruby NN_example_name/run.rb
```

| # | Directory | What it demonstrates |
|---|-----------|----------------------|
| 01 | `01_basic_chain/` | PromptTemplate → LLMChain pipeline |
| 02 | `02_react_agent/` | ReAct tool-calling agent |
| 03 | `03_state_graph/` | Stateful workflow with wait_state/send_event |
| 04 | `04_interrupt_resume/` | Human-in-the-loop wait_state and resume |
| 05 | `05_multi_agent/` | Multi-agent coordination via Agent-as-Tool |
| 06 | `06_guardrails/` | Input/output guardrails |
| 07 | `07_tracing/` | Custom observability with Langfuse tracer |
| 08 | `08_mcp_tool/` | MCP tool integration |
| 10 | `10_context_management/` | Token budget and context pruning |
| 11 | `11_agent_streaming/` | Streaming agent responses |
| 12 | `12_prompt_template/` | Advanced prompt templates |
| 13 | `13_mcp_http_tool/` | HTTP-based MCP tool server |
| 14 | `14_code_review/` | Automated code review agent |
| 17 | `17_multi_agent_handoff/` | Hub-and-spoke agent routing via Runner |

The following examples are **app-level demos** (Rails apps or advanced pipelines)
that require additional infrastructure (a running Rails server, database, etc.):

| # | Directory | What it demonstrates |
|---|-----------|----------------------|
| 09 | `09_rails_chat/` | Rails chat app with ActionCable streaming |
| 15 | `15_rails_secure_chat/` | Rails chat with PII guardrails |
| 18 | `18_rails_agent_job/` | Rails app with AgentJob + ActionCable streaming |
| 19 | `19_trust_pipeline/` | Generator-Verifier pattern with citation tracking, self-review loop and confidence gate |

## Development

After checking out the repo, install dependencies:

```bash
bin/setup
```

Run the unit test suite:

```bash
bundle exec rspec spec/phronomy
```

Run the integration tests (requires a running LLM endpoint):

```bash
bundle exec rspec spec/integration --tag integration
```

Launch an interactive console:

```bash
bin/console
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/Raizo-TCS/phronomy.

## Security & Privacy

**API credentials** — Phronomy does not store or transmit your LLM API keys. All
credentials are handled by RubyLLM and passed directly to the provider.

**Tracing and PII** — When tracing is enabled (`Phronomy::Tracing::OpenTelemetryTracer`
or a custom tracer), agent inputs and LLM outputs are replaced with `[REDACTED]` in
span attributes by default (`trace_pii: false`). To include full content in traces
(e.g., for debugging in a non-production environment), set `trace_pii: true` in your
Phronomy configuration. Evaluate whether your tracing backend (OTLP collector, Jaeger,
Honeycomb, etc.) meets your data-retention and privacy requirements.

**Prompt injection** — Phronomy provides `PromptInjectionFilter`, a built-in
pattern-based input filter that detects common injection patterns (ignore/override
instructions, role-switching phrases, etc.). It is a useful starting point, not a
comprehensive defence; applications processing untrusted input should layer additional
custom filters as needed (see the Filters section above).

**Tool and MCP security** — Tools can perform real-world side effects (database
writes, API calls, file deletion). Treat tool execution as a privileged operation:
use the interrupt/approval mechanism for high-risk tools (e.g., payment processing,
file deletion) rather than allowing fully autonomous execution. MCP servers are
external trust boundaries: connect only to servers you control. A compromised MCP
server can inject instructions that manipulate agent behavior (tool-level prompt
injection). Avoid passing secrets as direct tool parameters — if `trace_pii: true`
is set, tool arguments are captured in trace spans.

**Vulnerability reports** — Please report security vulnerabilities privately via
GitHub's [Security Advisories](https://github.com/Raizo-TCS/phronomy/security/advisories)
rather than opening a public issue.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
