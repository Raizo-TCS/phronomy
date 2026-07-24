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
| **Workflow action_timeout** — Per-state `action_timeout:` keyword on `state` DSL; cancels Task-returning entry actions that exceed the limit and raises `Phronomy::ActionTimeoutError` | Beta |
| **Agent** — ReAct-style tool-calling agents with guardrails and conversation history | Stable |
| **Before-Completion Hook** — Three-tier LLM parameter injection | Stable |
| **Context Management** — Token budget calculation, estimation, and pruning; `Agent::Base` protected hooks: `build_context` (overridable), `trim_messages`, `trim_to_budget`, `compact_messages`, `budget_exceeded?`, `drop_messages_over` | Stable |
| **Filters** — Input/output transformation and blocking via `Filter::Base`; call `block!(reason)` to reject and raise `FilterBlockError` | Beta |
| **`PromptInjectionFilter`** — Built-in `Filter::Base` subclass that detects prompt-injection patterns; usable standalone or as part of a filter chain | Beta |
| **`Agent::Context::Capability::Base.redact_params` / `.max_result_size`** — Class-level DSL: `redact_params` masks parameter values in log/trace output; `max_result_size` truncates oversized tool results before they reach the LLM | Beta |
| **Output Parser** — JSON and Struct-mapped parsers for structured LLM responses | Stable |
| **Eval Framework** — Dataset-driven evaluation with multiple scorer types | Beta |
| **Tracing** — Pluggable span-based observability | Stable |
| **Error Taxonomy** — `RateLimitError`, `AuthenticationError`, `ContextLengthError`, `TransportError` (subclasses of `Phronomy::Error`) raised at the agent retry boundary | Beta |

**Knowledge and integration**

| Feature | Stability |
|---|---|
| **Knowledge** — Static context injection with pluggable loaders, splitters, and vector stores; `static_knowledge_refresh!` for runtime cache invalidation | Beta |
| **`VectorStore#size`** — Returns document count for all three backends (InMemory, RedisSearch, Pgvector) | Beta |
| **`VectorStore::AsyncBackend` mixin** — Pluggable async interface for `VectorStore`; default pool-backed implementations for `search_async`, `add_async`, `remove_async`, `clear_async`; backends with native async drivers override individual methods to bypass `BlockingAdapterPool` entirely; all existing backends remain unchanged | Beta |
| **MCP Tool** — `Phronomy::Tools::Mcp`: Model Context Protocol server integration via the official `mcp` gem; `Phronomy::Tools::Agent`: wraps an agent class as a callable tool via `from_agent` | Beta |
| **Vector Search Tool** — `Phronomy::Tools::VectorSearch`: wraps a `VectorStore` and `Embeddings` adapter as a callable agent tool via `from_store` | Beta |

**Execution and reliability**

| Feature | Stability |
|---|---|
| **Workflow EventLoop Mode** — Opt-in event-driven execution: `Phronomy.configure { \|c\| c.event_loop = true }` | Experimental |
| **Agent EventLoop Mode** — `Agent#invoke` (non-blocking via EventLoop), `Agent#invoke_async` + `Task#map` (child-agent pattern for Workflow integration), parallel tool dispatch via `ParallelToolChat` | Experimental |
| **`invoke_async` / `call_async`** — `Agent::Base#invoke_async` and `Workflow#invoke_async` return a `Task`; `Agent::Context::Capability::Base#call_async` similarly; compatible with EventLoop and standalone contexts | Experimental |
| **`Task#map`** — transforms a `Task`'s completed value via a block; returns a new `Task` whose value is the block's return value; if the source task fails or is cancelled the mapped task propagates the error without calling the block; primary use-case: `invoke_async.map { \|r\| ctx.merge(answer: r[:output]) }` to wire agent results into a `WorkflowContext` | Experimental |
| **CancellationToken** — Cooperative cancellation via `cancel!`/`cancelled?`/`raise_if_cancelled!`; `timeout_after(seconds)` for monotonic-clock deadlines; optional `deadline:` (wall-clock) for backward compatibility; passed as `config: { cancellation_token: token }` to agents and `dispatch_parallel`; injected into `tool.execute` when the method declares a `cancellation_token:` keyword; bridged to `MCP::Cancellation` in `Phronomy::Tools::Mcp#execute` | Experimental |
| **`dispatch_parallel` / `fan_out` `force_kill:` option** — `force_kill: false` (default) leaves timed-out workers running and raises `TimeoutError` immediately; `force_kill: true` restores the old `Thread#kill` behaviour with a `logger.warn` | Beta |
| **`execution_mode` DSL on `Agent::Context::Capability::Base`** — Declares how a tool's `execute` should be dispatched: `:cooperative` (same scheduler thread), `:blocking_io` (default; offloaded to `BlockingAdapterPool`), `:cpu_bound`, `:external_process`; `config[:tool_timeout]` sets the per-submit timeout forwarded to `BlockingAdapterPool` for abandoned-operation tracking | Experimental |
| **`invocation_context:` keyword on `Agent#invoke` / `Workflow#invoke`** — Pass a `Phronomy::InvocationContext` directly; `thread_id`, `cancellation_token`, and `deadline`-based timeout are derived from it; `task_id` / `parent_task_id` appear in trace spans automatically; `config:` keys remain supported as backward-compat aliases | Beta |
| **Cooperative scheduler yield points** — `Runtime#yield` (cooperative yield; yields the current task's time slice); `Runtime#yield_if_needed(every: N)` (thread-local counter, yields every N calls); CPU-bound detection when `blocking_detect_threshold_ms` is set (warns and increments `non_yield_threshold_violation_count` when a task runs longer than the threshold without yielding); `starvation_threshold_ms` configuration field (default: 50ms) | Beta |
| **`Phronomy::Metrics`** — `Phronomy::Metrics.snapshot` returns task-tree and pool counters; task-centric keys: `active_agent_tasks`, `active_tool_tasks`, `active_workflow_tasks`, `active_llm_tasks`, `task_wait_time_p50_ms`, `task_wait_time_p95_ms`, `task_run_time_p50_ms`, `task_run_time_p95_ms`, `cancelled_tasks`, `failed_tasks`, `non_yield_threshold_violation_count`; pool/event-loop keys remain for backward compatibility; `Runtime#task_snapshot` exposes task-centric metrics directly | Beta |
| **`Phronomy.with_configuration` / `Phronomy.reset_runtime!`** — Scoped configuration override and full runtime reset for test isolation | Beta |

**Agent patterns**

| Feature | Stability |
|---|---|
| **Workflow parallel pattern** — Concurrent branches via application-level threads (no built-in parallel primitive; see the Workflow section for the recommended pattern) | Beta |
| **Multi-agent** — Agent-as-Tool pattern and hub-and-spoke handoff routing | Beta |
| **GeneratorVerifier** — Generator-Verifier loop with injectable prompt builders/parsers | Beta |
| **Agent::Orchestrator** — Parallel subagent dispatch, fan-out, and `subagent` DSL | Beta |
| **Agent::TeamCoordinator** — Agent teams pattern: LLM coordinator + stateful workers with sequential task assignment (worker-local message history persisted across tasks) | Beta |
| **Agent::SharedState** — Shared state pattern: peer agents collaborate via a shared KnowledgeStore; `member` DSL with per-agent instructions and `coordination` team protocol | Experimental |
| **`ScopePolicy`** — Configurable policy callable that maps (tool, scope, agent) to `:allow`/`:approve`/`:reject`; default policy auto-routes high-risk scopes through the approval gate | Experimental |
| **HITL Checkpoint/Resume** — `Agent::Base#invoke` returns `{ suspended: true, checkpoint: Checkpoint }` when an approval-required tool is encountered without a synchronous handler; `Agent::Base#resume(checkpoint, approved:)` resumes execution; `Agent::Base.resume(checkpoint, approved:)` (class-level) resolves the agent class automatically; `Checkpoint#to_h` / `Checkpoint.from_h` for serialization; `Agent::Base#checkpoint_store=` for custom idempotency backends; `CheckpointAlreadyResumedError` raised on duplicate resume | Experimental |
| **`Filter::Base` — unified value filter interface** — `Phronomy::Filter::Base` with a single abstract method `call(value, **context)`; apply to user input (`add_input_filter` / `input_filter` DSL), final LLM output (`add_output_filter` / `output_filter` DSL), or individual tool return values (`add_tool_result_filter(tool_class?, filter)` / `tool_result_filter` DSL); filters transform values and return the result, or raise `Phronomy::FilterBlockError` to reject; filter chains are composable; the same filter instance can be reused across all three sites | Beta |

> **Public API boundary**: The tables above are the complete list of classes, modules, and features
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
| **`Phronomy::Diagnostics`** — Snapshot of scheduler internals for debug/monitoring; `SchedulerReentrancyError` raised on invalid re-entrant scheduler use; `Runtime.in_scheduler_context?` returns `true` when called from inside a scheduler task | Experimental |
| **`Phronomy::Testing::FakeClock` / `FakeScheduler` / `SchedulerHelpers`** — Test helpers for deterministic concurrency specs: `FakeClock#advance(seconds)` controls time; `FakeScheduler` runs tasks synchronously and records `event_log`; `FakeScheduler#assert_order` / `#assert_cancelled` for ordering assertions; `FakeClock#advance_to_next_timer` fires the next pending callback; `Testing::SchedulerHelpers#with_fake_scheduler` replaces the global Runtime for the duration of a block | Beta |
| **`Configuration#runtime_backend`** — `:thread` (default, one OS thread per task), `:immediate` (tests — tasks run synchronously, no extra threads), `:fiber` (**EXPERIMENTAL** — experimental validation backend only: runs tasks as Ruby Fibers on a cooperative scheduler to verify that framework components are truly non-blocking; **not for production use** and not a planned production replacement for `:thread`; no preemptive scheduling will be added). `:cooperative` is a **deprecated alias** for `:immediate` — do not use in new code | Beta |
| **`Configuration#strict_runtime_guards`** — When `true`, calling `Agent#invoke` from inside a scheduler task raises `SchedulerReentrancyError`; when `false` (default) a warning is logged instead | Beta |

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
end
```

See the [RubyLLM documentation](https://rubyllm.com) for all supported providers.

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
  model "gpt-4o"
  instructions "You are a research assistant. Use tools to answer questions."
  tools WebSearch
  max_iterations 5
end

result = ResearchAgent.new.invoke("What happened in AI research this week?")
puts result[:output]
```

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

In EventLoop mode (`c.event_loop = true`), use `invoke_async + Task#map` to run an agent
asynchronously inside a Workflow entry action.  The mapped Task returns a `WorkflowContext`,
which `FSMSession` picks up via the standard `:action_completed` path:

```ruby
# EventLoop mode: workflow that runs an agent and captures the result.
entry :translate, ->(ctx) {
  TranslationAgent.new.invoke_async(ctx.query).map do |result|
    ctx.merge(answer: result[:output])   # returns WorkflowContext
  end
}
transition from: :translate, to: :done   # no on: needed
```

### Multi-Agent — Agent-as-Tool pattern

Wrap sub-agents as `Agent::Context::Capability::Base` subclasses so the orchestrator LLM can call them on demand.

```ruby
class ResearchTool < Phronomy::Agent::Context::Capability::Base
  description "Research a topic and return key findings as bullet points."
  param :topic, type: :string, desc: "The topic to research"

  def execute(topic:)
    ResearchAgent.new.invoke(topic)[:output]
  end
end

class WriterAgent < Phronomy::Agent::Base
  model "gpt-4o"
  instructions "You are a professional technical writer."
end

class WriteTool < Phronomy::Agent::Context::Capability::Base
  description "Write a technical blog post given research notes and a writing brief."
  param :instructions, type: :string, desc: "Writing brief including research notes"

  def execute(instructions:)
    WriterAgent.new.invoke(instructions)[:output]
  end
end

class OrchestratorAgent < Phronomy::Agent::Base
  model "gpt-4o"
  instructions "Use the research tool first, then the write tool to produce a blog post."
  tools ResearchTool, WriteTool
end

result = OrchestratorAgent.new.invoke("Write a blog post about Ruby 3.4 features")
puts result[:output]
```

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

### Knowledge — Static context injection

```ruby
# Static knowledge (policy files, reference docs)
policy = Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
  File.read("policy.md"),
  type:   :policy,
  source: "policy.md"   # exposed to LLM for citation
)

# Inject at invocation time via the agent DSL
class MyAgent < Phronomy::Agent::Base
  model "gpt-4o-mini"
  knowledge policy
end
```

`static_knowledge_refresh!` invalidates the class-level cache of static knowledge sources.
Call it when the underlying file or content has changed:

```ruby
# Static knowledge sources are cached at the class level after the first fetch.
# Call refresh! when the underlying content changes (e.g. after reloading policy.md).
MyAgent.static_knowledge_refresh!
```

Load and split documents with built-in loaders:

```ruby
chunks = Phronomy::VectorStore::Loader::MarkdownLoader.new.load("docs/guide.md")
         .then { |docs| Phronomy::VectorStore::Splitter::RecursiveSplitter.new(chunk_size: 512).split(docs) }
```

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

### Before-Completion Hook — Dynamic LLM parameter injection

```ruby
# Class-level: applies to all instances
class MyAgent < Phronomy::Agent::Base
  model "gpt-4o"
  before_completion ->(ctx) { { temperature: ctx.config[:precise] ? 0.0 : 0.7 } }
end

# Instance-level: overrides class hook for this agent only
agent = MyAgent.new
agent.before_completion = ->(ctx) { { max_tokens: 512 } }

# Global: applies to every agent across the app
Phronomy.configure do |c|
  c.before_completion = ->(ctx) { { temperature: 0.3 } }
end
```

Hooks are called in order — global → class → instance — and shallow-merged (`Hash#merge`; last hook wins on key conflicts).

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

### Agent::Orchestrator — Parallel subagent dispatch

> **Note:** `dispatch_parallel` and `fan_out` use plain Ruby threads. Use
> `max_concurrency:` to cap the number of concurrent workers and `on_error:`
> to control failure handling (`:raise` re-raises the first error after all
> tasks complete; `:skip` fills failed slots with `nil`). For very large
> fan-outs consider additional rate-limiting at the application level.

```ruby
class ResearchOrchestrator < Phronomy::Agent::Orchestrator
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
class MyOrchestrator < Phronomy::Agent::Orchestrator
  model "gpt-4o"
  instructions "Orchestrate."

  def run(query)
    # Heterogeneous agents in parallel (cap at 4 threads; skip failures; 30 s timeout)
    results = dispatch_parallel(
      {agent: SearchAgent,   input: "topic A"},
      {agent: AnalysisAgent, input: query},
      max_concurrency: 4,
      on_error: :skip,
      timeout: 30
    )

    # Fan-out — same agent, multiple inputs
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

### Workflow parallel pattern — Concurrent branches

Phronomy does not provide a dedicated parallel-node primitive. The recommended
pattern for concurrent branches is to use application-level Ruby threads inside
a `state` action:

```ruby
class EnrichContext
  include Phronomy::WorkflowContext
  field :summary, type: :replace
  field :tags,    type: :append, default: -> { [] }
end

app = Phronomy::Workflow.define(EnrichContext) do
  initial :enrich
  state :enrich, action: ->(s) do
    # Use Thread#value to collect results safely — avoids concurrent Hash writes
    threads = {
      summary: Thread.new { Summarizer.call(s) },
      tags:    Thread.new { Tagger.call(s) }
    }
    # For bounded waits, use Thread#join(timeout_seconds); nil means timed out — handle explicitly.
    # Do not use Timeout.timeout or Thread#kill — both inject async exceptions that bypass cleanup.
    # Prefer CancellationToken for cooperative cancellation of Phronomy-managed tasks.
    threads.each_value(&:join)
    s.merge(summary: threads[:summary].value, tags: Array(threads[:tags].value))
  end
  transition from: :enrich, to: :__finish__
end

state = app.invoke({}, config: { thread_id: "t1" })
```

### Output Parser — Structured LLM responses

```ruby
# Extract JSON from LLM output (handles Markdown code fences automatically)
parser = Phronomy::OutputParser::JsonParser.new
data   = parser.parse('```json\n{"name":"Alice","score":0.9}\n```')
# => { name: "Alice", score: 0.9 }

# Map JSON directly to a Struct
PersonSchema = Struct.new(:name, :age, keyword_init: true)
parser = Phronomy::OutputParser::StructuredParser.new(PersonSchema)
person = parser.parse('{"name":"Alice","age":30}')
# => #<struct PersonSchema name="Alice", age=30>
```

### Eval Framework — Dataset-driven quality evaluation

```ruby
dataset = Phronomy::Eval::Dataset.from_array([
  { input: "Capital of France?", expected: "Paris" },
  { input: "Capital of Japan?",  expected: "Tokyo" }
])

agent   = MyGeographyAgent.new
runner  = Phronomy::Eval::Runner.new(
  scorer: Phronomy::Eval::Scorer::LlmJudge.new(model: "gpt-4o-mini")
)

results = runner.run(dataset, ->(q) { agent.invoke(q) })
metrics = Phronomy::Eval::Metrics.new(results)

puts "Mean score: #{metrics.mean_score}"   # Float 0.0–1.0
puts "Pass rate:  #{metrics.pass_rate}"    # fraction with score >= threshold
```

### Tracing — Custom observability

```ruby
Phronomy.configure do |c|
  c.tracer = MyCustomTracer.new  # any Phronomy::Tracing::Base subclass
end
```

### MCP Tool — External tool servers

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

### Conversation History — passing prior messages

Phronomy does not manage conversation history internally. The application owns the
message array and passes it in via the `messages:` keyword argument:

```ruby
# First turn
result1 = MyAgent.new.invoke("Hello! I'm Alice.", thread_id: "session-1")
prior_messages = result1[:messages]   # Array<RubyLLM::Message>

# Second turn — pass prior messages so the agent has context
result2 = MyAgent.new.invoke(
  "What is my name?",
  messages: prior_messages,
  thread_id: "session-1"
)
puts result2[:output]   # => "Your name is Alice."
```

`result[:messages]` contains the complete message history after each invocation.
Persist it however suits your application (in-memory hash, Redis, ActiveRecord, etc.).

> **Note on `thread_id`**: `thread_id` is a correlation identifier used internally for
> checkpoint/compaction context and EventLoop routing. It does **not** automatically persist or
> restore conversation history — you must pass `messages:` explicitly on each turn as shown above.


## Configuration

```ruby
Phronomy.configure do |c|
  c.default_model                   = "gpt-4o-mini"
  c.recursion_limit                 = 25
  c.tracer                          = Phronomy::Tracing::NullTracer.new
  c.before_completion               = nil   # optional; global hook lambda
  c.trace_pii                       = false # default; set to true only when trace data contains no PII
  c.logger                          = nil   # optional; any object responding to #warn (e.g. Rails.logger)
  c.event_loop_stop_grace_seconds   = 5     # seconds to wait for sessions to drain on EventLoop#stop(drain: true)
  c.runtime_backend                 = :thread   # :thread (default); :immediate (tests, synchronous); :fiber (experimental validation only); :cooperative (deprecated alias for :immediate)
  c.strict_runtime_guards           = false          # when true, raises on invoke-inside-task
end
```

`c.logger` receives framework diagnostic messages (e.g. unreachable-state warnings from
`Workflow.define`). When `nil` (default), messages are written to `$stderr` via `Kernel#warn`.

> **Note**: When `trace_pii = false`, both the _input_ and the _output_ (LLM
> responses and tool results) are replaced with `[REDACTED]` in trace spans.
> The default is `false` (PII protection enabled). Set to `true` only when
> trace data does not contain sensitive information.

## Sync vs Async API

Phronomy provides both synchronous and asynchronous invocation APIs.
Understanding when to use each prevents scheduler stalls and hidden deadlocks.

| Context | Recommended API |
|---------|----------------|
| Top-level application code, Rails controller, background job | `agent.invoke(input)` — blocks the calling thread until done |
| Workflow action / EventLoop callback | `agent.invoke_async(input).map { |r| ctx.merge(output: r[:output]) }` — returns a Task and resumes by state transition |
| Top-level code that wants explicit async | `agent.invoke_async(input).wait_result` — blocks the calling thread until the Task completes |

### Why this matters

`invoke` is a synchronous wrapper that calls `invoke_async` and then _blocks_ the calling
thread until the task completes.  It is intended for top-level application threads such as
Rails controller actions, CLI scripts, or background jobs.  Inside EventLoop-driven
workflow actions, return a Task and let `Task#map` / `Task#on_complete` drive the next
state transition instead of waiting inside the EventLoop thread.

### Runtime guard

Phronomy detects this pattern automatically:

```ruby
# Default (soft mode): logs a warning and continues
Phronomy.configure { |c| c.strict_runtime_guards = false }

# Strict mode: raises SchedulerReentrancyError immediately
Phronomy.configure { |c| c.strict_runtime_guards = true }
```

You can also query the current context directly:

```ruby
Phronomy::Runtime.in_scheduler_context?  # => true if called from inside a task
```

### Migration: blocking wait → Task mapping

```ruby
# Top-level synchronous use
result = my_agent.invoke("Hello")

# Explicit async from top-level code
result = my_agent.invoke_async("Hello").wait_result

# Workflow action / EventLoop-safe use
NODE = ->(ctx) {
  my_agent.invoke_async("Hello").map { |result|
    ctx.merge(answer: result[:output])
  }
}
```

### :immediate backend (synchronous / test mode)

The `:immediate` backend runs tasks synchronously using `FakeScheduler`
(backed by `Task::ImmediateBackend`).  Blocking I/O is isolated in `BlockingAdapterPool`.
To switch back to the default thread-per-task backend:

```ruby
Phronomy.configure { |c| c.runtime_backend = :thread }
# or per-example using SchedulerHelpers:
include Phronomy::Testing::SchedulerHelpers
with_fake_scheduler do |sched|
  # all spawns run synchronously; sched.event_log records every lifecycle event
end
```

## Context Management

Phronomy includes a context window management layer. When model metadata is
available (either from the built-in registry or via an explicit `context_window:` setting),
agents automatically stay within the configured token limit.

### TokenBudget

Derives the effective token budget from RubyLLM's model registry:

```ruby
budget = Phronomy::LlmContextWindow::TokenBudget.new(
  model:    "claude-3-5-sonnet-20241022",  # looks up context_window + max_output_tokens
  overhead: 500                            # extra reservation for tool definitions
)
budget.context_window       # => 200_000
budget.max_output_tokens    # => 8_192
budget.effective_input_limit # => 191_308
```

Or supply explicit values (useful for local / unregistered models):

```ruby
budget = Phronomy::LlmContextWindow::TokenBudget.new(
  context_window:    32_768,
  max_output_tokens: 4_096
)
```

### Agent DSL extensions

```ruby
class MyAgent < Phronomy::Agent::Base
  model "gpt-4o"
  max_output_tokens 4096   # override max_output_tokens from registry
  context_overhead  600    # extra reservation for system prompt + tools
  invoke_timeout    30     # raise Phronomy::TimeoutError after 30 s (wait timeout, not cancellation)
  max_parallel_tools 4     # cap concurrent tool executions (default: 10)
end
```

`Agent::Base#invoke` builds a `TokenBudget` automatically. When the model is not in the
registry the budget is silently skipped.

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
after each streaming chunk, before each parallel
tool-call batch, and after each `before_completion` hook. `CancellationError` is
raised immediately and is never retried. No threads are force-killed — `ensure`
blocks always execute.

> **Cooperative cancellation — not preemptive**
>
> Phronomy uses _cooperative boundary cancellation_. The token is polled at the
> checkpoints listed above; it is **not** injected as a signal into a running
> operation. This means the following are **not** interrupted mid-execution:
>
> - A single `KnowledgeSource#fetch` that is already blocking (e.g. HTTP call)
> - A single `chat.ask` call that is not streaming
> - A single `tool.execute` call that is already running
> - Any external I/O (database query, vector search, HTTP request) inside those calls
>
> For deep in-flight safety, complement `CancellationToken` with per-source or
> per-tool timeouts. Prefer library-native timeouts such as `Net::HTTP#read_timeout`,
> database `statement_timeout`, or Redis client timeout — these signal the I/O layer
> to abort cleanly. Avoid `Timeout.timeout` unless you understand its async-exception
> risks: it injects `Timeout::Error` at an arbitrary execution point (the same
> mechanism as `Thread#kill`), which Phronomy avoids by default due to resource
> safety concerns. Ruby's GVL prevents fully preemptive cancellation without such
> risky interruption.

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

> **`config[:tool_timeout]` / `config[:llm_timeout]` — caller protection, not
> worker termination**
>
> These keys set a per-submit timeout in `BlockingAdapterPool`. When the timeout
> fires, the *caller* receives `CancellationError` / `TimeoutError` immediately and
> the operation is marked as abandoned — but the worker thread continues executing
> until the underlying I/O completes naturally (e.g. `Net::HTTP` read, stdio
> `gets`). Size `blocking_io_pool_size` to account for the worst-case number of
> concurrently abandoned workers that may accumulate before the pool is saturated.

```ruby
token = Phronomy::Concurrency::CancellationToken.new

# Cancel from another thread after 5 s
Thread.new { sleep 5; token.cancel! }

begin
  result = MyAgent.new.invoke("...", config: { cancellation_token: token })
rescue Phronomy::CancellationError
  puts "cancelled"
end

# Hard deadline via monotonic clock (recommended — immune to NTP/DST changes)
token = Phronomy::Concurrency::CancellationToken.timeout_after(30)
result = MyAgent.new.invoke("...", config: { cancellation_token: token })

# Hard deadline via wall-clock (legacy — still supported)
token = Phronomy::Concurrency::CancellationToken.new(deadline: Time.now + 30)
result = MyAgent.new.invoke("...", config: { cancellation_token: token })

# Propagate to all parallel workers via dispatch_parallel / fan_out
token = Phronomy::Concurrency::CancellationToken.new
Thread.new { sleep 10; token.cancel! }

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
| 16 | `16_before_completion_hook/` | Global/class/instance before_completion hooks |
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
