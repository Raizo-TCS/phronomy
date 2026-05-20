# Phronomy

**Phronomy** is a Ruby AI agent framework inspired by open-source AI agent frameworks.  
It provides composable building blocks — Workflows, Agents, Tools, Guardrails, RAG, and Tracing — all powered by [RubyLLM](https://github.com/crmne/ruby_llm) for LLM abstraction.

## Features

> **Stability labels**: `Stable` — production-ready, semver-protected API.
> `Beta` — functional but the API may change in a minor release.
> `Experimental` — subject to breaking changes without notice.

| Feature | Stability |
|---|---|
| **Workflow** — Stateful, branching workflows with wait_state/send_event | Stable |
| **Workflow Parallel Node** — Concurrent branches via application-level threads | Beta |
| **Agent** — ReAct-style tool-calling agents with guardrails and conversation history | Stable |
| **Before-Completion Hook** — Three-tier LLM parameter injection | Stable |
| **Context Management** — Token budget calculation, estimation, and pruning | Stable |
| **Knowledge/RAG** — Retrieval sources with pluggable loaders, splitters, and vector stores | Beta |
| **Multi-agent** — Agent-as-Tool pattern and hub-and-spoke handoff routing | Beta |
| **GeneratorVerifier** — Generator-Verifier loop with injectable prompt builders/parsers | Beta |
| **Agent::Orchestrator** — Parallel subagent dispatch, fan-out, and `subagent` DSL | Beta |
| **Agent::TeamCoordinator** — Agent teams pattern: LLM coordinator + stateful worker pool with task queue (worker-local message history per run) | Beta |
| **Agent::SharedState** — Shared state pattern: peer agents collaborate via a shared KnowledgeStore; `member` DSL with per-agent instructions and `coordination` team protocol | Experimental |
| **Guardrails** — Input/output validation; built-in PII and prompt-injection detectors | Beta |
| **Output Parser** — JSON and Struct-mapped parsers for structured LLM responses | Stable |
| **Eval Framework** — Dataset-driven evaluation with multiple scorer types | Beta |
| **Tracing** — Pluggable span-based observability | Stable |
| **MCP Tool** — Model Context Protocol server integration | Beta |

## Installation

Add to your Gemfile:

```ruby
gem "phronomy"
```

Then run:

```bash
bundle install
```

## Quick Start

### Agent — ReAct tool-calling agent

```ruby
class WebSearch < Phronomy::Tool::Base
  description "Search the web"
  param :query, type: :string, desc: "Search query"

  def execute(query:)
    # ... call a search API
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

```ruby
class ReviewContext
  include Phronomy::WorkflowContext
  field :draft,    type: :replace
  field :feedback, type: :replace
  field :approved, type: :replace, default: false
end

app = Phronomy::Workflow.define(ReviewContext) do
  initial :write
  state     :write,    action: ->(s) { s.merge(draft: Writer.call(s)) }
  state     :review,   action: ->(s) { s.merge(feedback: Reviewer.call(s.draft)) }
  wait_state :awaiting_approval           # halts here for human decision
  state     :finalize, action: ->(s) { s.merge(approved: true) }
  after :write,    to: :review
  after :review,   to: :awaiting_approval
  after :finalize, to: :__finish__
  event :approve, from: :awaiting_approval, to: :finalize
  event :reject,  from: :awaiting_approval, to: :write
end

# First run — halts at :awaiting_approval
state = app.invoke({ draft: "" }, config: { thread_id: "doc-1" })
puts "Halted: #{state.halted?}"   # => true
puts "Draft: #{state.draft}"

# Resume after human approval — pass the halted state and the event name
final = app.send_event(state: state, event: :approve)
puts "Approved: #{final.approved}"  # => true
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

```ruby
class NoSensitiveDataGuardrail < Phronomy::Guardrail::InputGuardrail
  def check(input)
    fail!("Credit card numbers are not allowed") if input.match?(/\d{4}-\d{4}-\d{4}-\d{4}/)
  end
end

agent = ResearchAgent.new
agent.add_input_guardrail(NoSensitiveDataGuardrail.new)
```

### Built-in Guardrails — PII and prompt injection detection

```ruby
# Detect SSNs, credit cards, emails, and phone numbers
agent.add_input_guardrail(Phronomy::Guardrail::Builtin::PIIPatternDetector.new)

# Block common prompt-injection attempts
agent.add_input_guardrail(Phronomy::Guardrail::Builtin::PromptInjectionDetector.new)
```

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
rag = Phronomy::KnowledgeSource::RAGKnowledge.new(store: store, embeddings: embeddings, k: 5)

# Inject at invocation time
result = MyAgent.new.invoke("What is the refund policy?",
  config: { knowledge_sources: [policy, rag] })
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

Hooks are called in order — global → class → instance — and deep-merged.

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
    # Heterogeneous agents in parallel (cap at 4 threads; skip failures)
    results = dispatch_parallel(
      {agent: SearchAgent,   input: "topic A"},
      {agent: AnalysisAgent, input: query},
      max_concurrency: 4,
      on_error: :skip
    )

    # Fan-out — same agent, multiple inputs
    translations = fan_out(
      agent: TranslationAgent,
      inputs: %w[Hello World],
      max_concurrency: 2
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
    results = {}
    threads = [
      Thread.new { results[:summary] = Summarizer.call(s) },
      Thread.new { results[:tags]    = Tagger.call(s) }
    ]
    threads.each { |t| t.join(10) }  # 10-second timeout
    s.merge(summary: results[:summary], tags: Array(results[:tags]))
  end
  after :enrich, to: :__finish__
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


## Configuration

```ruby
Phronomy.configure do |c|
  c.default_model       = "gpt-4o-mini"
  c.recursion_limit     = 25
  c.tracer              = Phronomy::Tracing::NullTracer.new
  c.before_completion   = nil   # optional; global hook lambda
end
```

## Context Management

Phronomy includes a context window management layer so agents automatically
stay within the token limits of the underlying model.

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
end
```

`Agent::Base#invoke` builds a `TokenBudget` automatically. When the model is not in the
registry the budget is silently skipped.


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

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
