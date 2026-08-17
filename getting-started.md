# Getting started

This guide contains the setup and introductory examples that were previously
embedded in the repository README. The README remains the project entry point;
this document carries the longer operational examples.

## Install

Add Phronomy to your Gemfile:

```ruby
gem "phronomy"
```

Then run:

```bash
bundle install
```

Phronomy uses RubyLLM for Large Language Model (LLM) access. Configure provider credentials and the
transport retry/timeout policy on RubyLLM itself:

```ruby
RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  # c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]

  c.request_timeout = 120
  c.max_retries = 3
  c.retry_interval = 0.1
  c.retry_backoff_factor = 2
  c.retry_interval_randomness = 0.5
end
```

Phronomy does not add a second LLM transport timeout/retry layer on top of the
configured adapter.

## Optional dependencies

Install only the backend gems required by your application:

| Gem | Required for |
|---|---|
| `pgvector` | `Phronomy::VectorStore::Pgvector` |
| `redis` | `Phronomy::VectorStore::RedisSearch` |
| `opentelemetry-api` | `Phronomy::Tracing::OpenTelemetryTracer` |

## Define a Tool and Agent

Use `Phronomy::Tool::Base` as the application-facing authoring API. It is an
exact alias of the existing `Phronomy::Agent::Context::Capability::Base`, so
existing Tool definitions using the longer namespace remain compatible.

```ruby
class WebSearch < Phronomy::Tool::Base
  description "Search the web"
  param :query, type: :string, desc: "Search query"

  def execute(query:)
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

result = ResearchAgent.new.invoke("Research Ruby AI frameworks")
puts result[:output]
```

Every concrete stateful Agent definition declares a stable definition ID and
version. The definition identity is checked when persisted Agent state is loaded.

## Stateful Agent persistence

Phronomy Agents own their conversation history and persistent Knowledge. The
application does not need to pass the previous `messages` array back into every
invocation.

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

Load the same Agent again when the same Persistence backend is available:

```ruby
agent = ResearchAgent.load(
  "research-session-42",
  persistence: persistence
)

agent.invoke("Continue our previous discussion.")
```

`load` is the hydration boundary. While that Agent instance is live, the
instance and its active `AgentExecutionActivation` own the current logical state.
Phronomy persists snapshots at defined durability boundaries but does not reload
mutable Agent/Execution/Journal state before every LLM or Tool step. A conflicting
external durable write is surfaced as `Persistence::ConflictError` rather than
silently merged into the live instance.

The active transcript and Knowledge views can be advanced independently without
deleting the append-only canonical Journal:

```ruby
agent.clear_transcript!
agent.clear_knowledge!
agent.reset_context!
```

`purge!` is different: it permanently removes the Agent and persisted execution
history from the configured Persistence backend.

## Sync and async Agent APIs

Use synchronous APIs at an external/top-level application boundary and async
APIs when the caller must remain non-blocking.

```ruby
result = agent.invoke("Hello")

task = agent.invoke_async("Hello")
result = task.wait_result
```

Both `invoke` and `invoke_async` can receive public Agent events through either
an `on_event:` listener or a block. A block is convenient when the listener is
local to the call:

```ruby
task = agent.invoke_async("Hello") do |event|
  puts event.payload[:output] if event.type == :done
end
```

Use `on_event:` when the listener already exists as a callable. Do not provide
both `on_event:` and a block to the same invocation.

`Phronomy::Task` is the common caller-facing completion handle for asynchronous
Phronomy work. Logical lifecycle progress is driven by EventLoop/FSMSession;
synchronous work that must execute away from EventLoop is submitted to
OffloadPool. Both paths expose completion as a `Task`.

`Task#wait_result` is for an external caller. Do not block EventLoop waiting for
a Task that can only complete through that same EventLoop.

Streaming follows the same split:

```ruby
agent.stream("Explain the design") do |event|
  puts event.payload if event.type == :token
end
```

```ruby
task = agent.stream_async("Explain the design") do |event|
  puts event.payload if event.type == :token
end
```

Agent event callbacks execute on EventLoop and therefore should return quickly.

## Human-in-the-loop approval

A Tool requiring approval can suspend an Agent invocation. Resume it with the
approval request identifier returned by the suspension result.

At a top-level synchronous boundary:

```ruby
result = agent.invoke("Perform the requested protected action")

if result[:suspended]
  request = result[:approval_request]
  result = agent.approve(
    result[:execution_id],
    approval_request_id: request.id,
    approved: true
  )
end
```

From an EventLoop callback, use `approve_async` rather than blocking EventLoop.
Approval resume continues the same live Agent instance, Activation, and
AgentInvocation; it is not an Agent reload boundary.

## Workflow basics

A Workflow is state-machine-driven and can halt at an explicit wait state:

```ruby
class ReviewContext
  include Phronomy::WorkflowContext
  field :draft,    type: :replace
  field :feedback, type: :replace
  field :approved, type: :replace, default: false
end

write_draft  = ->(state) { state.merge(draft: "Draft content") }
review_draft = ->(state) { state.merge(feedback: "Feedback on: #{state.draft}") }

persistence = Phronomy::Persistence::InMemory.new

workflow = Phronomy::Workflow.define(
  ReviewContext,
  persistence: persistence
) do
  initial :write
  state :write, action: write_draft
  state :review, action: review_draft
  wait_state :awaiting_approval
  state :finalize, action: ->(s) { s.merge(approved: true) }

  transition from: :write, to: :review
  transition from: :review, to: :awaiting_approval
  transition from: :awaiting_approval, on: :approve, to: :finalize
  transition from: :awaiting_approval, on: :reject, to: :write
  transition from: :finalize, to: :__finish__
end

state = workflow.invoke({draft: ""}, config: {thread_id: "doc-1"})
final = workflow.send_event(state: state, event: :approve)
puts final.approved
```

`Persistence#workflow_states` is the durable Workflow repository. `thread_id`
identifies the durable Workflow state and remains stable across resume. Each
concrete Runtime execution receives a separate internal `fsm_session_id`; the
application-level `session_id` remains ordinary caller/tracing metadata. Phronomy
holds owner-aware admission for `thread_id` from durable load through terminal
save so another local invocation cannot start from a stale snapshot while the
current owner is still committing.

A global Persistence backend can be configured when Agents and Workflows should
share one durable backend:

```ruby
Phronomy.configure do |config|
  config.persistence = persistence
end
```

Agent `new`/`create` and Workflow definitions use the global backend when they do
not inject an explicit `persistence:`. Workflow durability is fixed at the
application/Workflow-definition boundary; there is no per-invocation backend
switch.

Workflow entry and transition actions are synchronous Run-to-Completion
callbacks. If a Workflow needs an Agent or another asynchronous lifecycle, start
it asynchronously, return the Workflow context immediately, and deliver its
completion later with `Workflow#signal`.

```ruby
class AnswerContext
  include Phronomy::WorkflowContext

  field :question, type: :replace, default: ""
  field :answer,   type: :replace, default: nil
  field :thread_id, type: :replace, default: nil
end

class ResearchAgent < Phronomy::Agent::Base
  agent_definition id: "research-agent", version: 1
  model "gpt-4o-mini"
  instructions "Research the question and return a concise answer."
end

my_agent = ResearchAgent.new
workflow = nil

workflow = Phronomy::Workflow.define(AnswerContext) do
  initial :asking
  state :asking
  state :done

  entry :asking, ->(ctx) {
    thread_id = ctx.thread_id

    my_agent.invoke_async(ctx.question) do |event|
      next unless event.type == :done

      workflow.signal(
        thread_id: thread_id,
        event: :answer_ready,
        payload: {answer: event.payload[:output]}
      )
    end

    ctx
  }

  transition(
    from: :asking,
    on: :answer_ready,
    to: :done,
    action: ->(ctx, event) { ctx.merge(answer: event.payload[:answer]) }
  )
end
```

Returning a `Phronomy::Task` from a Workflow entry/transition action is not an
implicit await mechanism and is rejected.

## Agent as Tool

Expose a child Agent using `Phronomy::Tools::Agent.from_agent` rather than calling
a synchronous child Agent from a Tool worker:

```ruby
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

Agent-backed Tools return control to EventLoop while the child lifecycle is
waiting. They do not occupy an OffloadPool worker merely to wait for a child
Agent result.

## Filters

Filters can transform or reject values at Agent boundaries:

```ruby
class NoCreditCardFilter < Phronomy::Filter::Base
  def call(value, **_context)
    block!("Credit card numbers are not allowed") if value.match?(/\d{4}-\d{4}-\d{4}-\d{4}/)
    value
  end
end

agent.add_input_filter(NoCreditCardFilter.new)
```

Phronomy includes `PromptInjectionFilter` as a baseline pattern filter. It is not
a complete security policy for untrusted input.

## Persistent Knowledge and per-call context

Register durable Knowledge on the Agent:

```ruby
agent.add_knowledge(
  "Customer locale: ja-JP",
  metadata: {"origin" => "customer_profile"}
)
```

Request-scoped context can instead be supplied through `before_llm_input` using
`LLMInputPatch#segment_candidates`; those candidates enter Context Policy for the
specific call and are not persisted to the Journal.

## Model Context Protocol (MCP)

Phronomy targets MCP 1.x through the official `mcp` gem:

```ruby
search_tool = Phronomy::Tools::Mcp.from_server(
  "stdio://./mcp-server",
  tool_name: "web_search"
)

begin
  # use search_tool
ensure
  search_tool.close
end
```

See [MCP client](mcp-client.md) for schema, error, cancellation, and lifecycle
contracts.

## Next steps

- [Features and API stability](features.md)
- [Runtime and concurrency](runtime-and-concurrency.md)
- [Architecture decisions](decisions/)
- [Migration guides](migrations/)
