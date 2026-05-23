# Phronomy

> **⚠️ Development Notice**
> This project is primarily developed and maintained by **AI coding agents**.
> As a result, `main` receives frequent, large, and unannounced changes.
> External contributors should expect significant churn and potential conflicts at any time.
> We apologise for the instability this may cause.

**Phronomy** is a Ruby AI agent framework inspired by open-source AI agent frameworks.  
It provides composable building blocks — Workflows, Agents, Tools, Guardrails, RAG, and Tracing — all powered by [RubyLLM](https://github.com/crmne/ruby_llm) for LLM abstraction.

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

| Feature | Stability |
|---|---|
| **Workflow** — Stateful, branching workflows with wait_state/send_event | Stable |
| **Workflow EventLoop Mode** — Opt-in event-driven execution: `Phronomy.configure { \|c\| c.event_loop = true }` | Experimental |
| **Agent EventLoop Mode** — `Agent#invoke` (non-blocking via EventLoop), `Agent#run_as_child` (child-FSM pattern for Workflow integration), parallel tool dispatch via `ParallelToolChat` | Experimental |
| **Workflow Parallel Node** — Concurrent branches via application-level threads | Beta |
| **Agent** — ReAct-style tool-calling agents with guardrails and conversation history | Stable |
| **Before-Completion Hook** — Three-tier LLM parameter injection | Stable |
| **Context Management** — Token budget calculation, estimation, and pruning | Stable |
| **Knowledge/RAG** — Retrieval sources with pluggable loaders, splitters, and vector stores; `static_knowledge_refresh!` for runtime cache invalidation | Beta |
| **Multi-agent** — Agent-as-Tool pattern and hub-and-spoke handoff routing | Beta |
| **GeneratorVerifier** — Generator-Verifier loop with injectable prompt builders/parsers | Beta |
| **Agent::Orchestrator** — Parallel subagent dispatch, fan-out, and `subagent` DSL | Beta |
| **Agent::TeamCoordinator** — Agent teams pattern: LLM coordinator + stateful workers with sequential task assignment (worker-local message history persisted across tasks) | Beta |
| **Agent::SharedState** — Shared state pattern: peer agents collaborate via a shared KnowledgeStore; `member` DSL with per-agent instructions and `coordination` team protocol | Experimental |
| **Guardrails** — Input/output validation with custom `InputGuardrail`/`OutputGuardrail` | Beta |
| **Output Parser** — JSON and Struct-mapped parsers for structured LLM responses | Stable |
| **Eval Framework** — Dataset-driven evaluation with multiple scorer types | Beta |
| **Tracing** — Pluggable span-based observability | Stable |
| **MCP Tool** — Model Context Protocol server integration | Beta |
| **Error Taxonomy** — `RateLimitError`, `AuthenticationError`, `ContextLengthError`, `TransportError` (subclasses of `Phronomy::Error`) raised at the agent retry boundary | Beta |
| **`Phronomy.with_configuration` / `Phronomy.reset_runtime!`** — Scoped configuration override and full runtime reset for test isolation | Beta |

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
class WebSearch < Phronomy::Tool::Base
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

In EventLoop mode (`c.event_loop = true`), `Agent#run_as_child` spawns a child agent
asynchronously. When the child succeeds, `:child_completed` is dispatched; when it fails,
`:child_failed` is dispatched. Always declare both transitions to avoid a stuck workflow:

```ruby
# EventLoop mode: workflow that runs an agent as a child FSM
entry :run_agent, ->(ctx) {
  MyAgent.new.run_as_child(ctx.query, ctx: ctx) { |r| ctx.answer = r[:output] }
}
transition from: :run_agent, on: :child_completed, to: :done
transition from: :run_agent, on: :child_failed,    to: :handle_error
```

### Multi-Agent — Agent-as-Tool pattern

Wrap sub-agents as `Tool::Base` subclasses so the orchestrator LLM can call them on demand.

```ruby
class ResearchTool < Phronomy::Tool::Base
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

class WriteTool < Phronomy::Tool::Base
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

### Guardrails — Input/output validation

Call `fail!(reason)` inside `check` to reject — it raises `Phronomy::GuardrailError`.
When a guardrail rejects, `invoke` raises instead of returning an output.

```ruby
class NoSensitiveDataGuardrail < Phronomy::Guardrail::InputGuardrail
  def check(input)
    fail!("Credit card numbers are not allowed") if input.match?(/\d{4}-\d{4}-\d{4}-\d{4}/)
  end
end

agent = ResearchAgent.new
agent.add_input_guardrail(NoSensitiveDataGuardrail.new)

begin
  agent.invoke("Charge 4111-1111-1111-1111")
rescue Phronomy::GuardrailError => e
  puts e.message   # => "Credit card numbers are not allowed"
end
```

> **Limitations:** Phronomy ships no built-in guardrail implementations. There is no
> built-in prompt injection detector, PII scanner, or content classifier. All guardrail
> logic must be implemented by the application. Reference implementations for common
> patterns are available in `phronomy-examples` (example 06).

### Knowledge/RAG — Context injection and vector retrieval

```ruby
# Static knowledge (policy files, reference docs)
policy = Phronomy::KnowledgeSource::StaticKnowledge.new(
  File.read("policy.md"),
  type:   :policy,
  source: "policy.md"   # exposed to LLM for citation
)

# RAG retrieval from a vector store
store      = Phronomy::VectorStore::InMemory.new
embeddings = Phronomy::Embeddings::RubyLLMEmbeddings.new(model: "text-embedding-3-small")

# Add documents before querying
text1 = "Refunds are processed within 5 business days."
text2 = "Contact support@example.com for refund requests."
store.add(id: "doc-1", embedding: embeddings.embed(text1), metadata: { content: text1, source: "policy.md" })
store.add(id: "doc-2", embedding: embeddings.embed(text2), metadata: { content: text2, source: "policy.md" })

rag = Phronomy::KnowledgeSource::RAGKnowledge.new(store: store, embeddings: embeddings, k: 5)

# Inject at invocation time
result = MyAgent.new.invoke("What is the refund policy?",
  config: { knowledge_sources: [policy, rag] })
```

`static_knowledge_refresh!` invalidates the class-level cache of *static* knowledge sources
(not RAG stores). Call it when the underlying file or content has changed:

```ruby
# Static knowledge sources are cached at the class level after the first fetch.
# Call refresh! when the underlying content changes (e.g. after reloading policy.md).
MyAgent.static_knowledge_refresh!
```

Load and split documents with built-in loaders:

```ruby
chunks = Phronomy::Loader::MarkdownLoader.new.load("docs/guide.md")
         .then { |docs| Phronomy::Splitter::RecursiveSplitter.new(chunk_size: 512).split(docs) }
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

### Workflow Parallel Node — Concurrent branches

Phronomy does not provide a built-in parallel abstraction. Use application-level Ruby threads inside a `state` action:

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
    # For production use, wrap with Timeout.timeout to avoid unbounded waits:
    #   require "timeout"
    #   Timeout.timeout(30) { threads.each_value(&:join) }
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
search_tool = Phronomy::Tool::McpTool.from_server(
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
  c.default_model       = "gpt-4o-mini"
  c.recursion_limit     = 25
  c.tracer              = Phronomy::Tracing::NullTracer.new
  c.before_completion   = nil   # optional; global hook lambda
  c.trace_pii           = false # default; set to true only when trace data contains no PII
  c.logger              = nil   # optional; any object responding to #warn (e.g. Rails.logger)
end
```

`c.logger` receives framework diagnostic messages (e.g. unreachable-state warnings from
`Workflow.define`). When `nil` (default), messages are written to `$stderr` via `Kernel#warn`.

> **Note**: When `trace_pii = false`, both the _input_ and the _output_ (LLM
> responses and tool results) are replaced with `[REDACTED]` in trace spans.
> The default is `false` (PII protection enabled). Set to `true` only when
> trace data does not contain sensitive information.

## Context Management

Phronomy includes a context window management layer. When model metadata is
available (either from the built-in registry or via an explicit `context_window:` setting),
agents automatically stay within the configured token limit.

### TokenBudget

Derives the effective token budget from RubyLLM's model registry:

```ruby
budget = Phronomy::Context::TokenBudget.new(
  model:    "claude-3-5-sonnet-20241022",  # looks up context_window + max_output_tokens
  overhead: 500                            # extra reservation for tool definitions
)
budget.context_window       # => 200_000
budget.max_output_tokens    # => 8_192
budget.effective_input_limit # => 191_308
```

Or supply explicit values (useful for local / unregistered models):

```ruby
budget = Phronomy::Context::TokenBudget.new(
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
  max_parallel_tools 4     # cap concurrent tool-call threads (default: 10)
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
> Phronomy::Context::TokenEstimator.tokenizer = ->(text) { enc.encode(text).length }
> ```


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

**Prompt injection** — Phronomy provides no built-in prompt injection detection.
Applications that process untrusted user input should implement their own input
guardrails (see the Guardrails section above).

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
