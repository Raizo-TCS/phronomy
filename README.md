# Phronomy

> **⚠️ Development Notice**
> This project is primarily developed and maintained by **AI coding agents**.
> As a result, `main` receives frequent, large, and unannounced changes.
> External contributors should expect significant churn and potential conflicts at any time.
> Correct responsibility boundaries and behavior take priority over backward compatibility.
> Obsolete APIs and compatibility-only paths are removed; update applications with the documented API changes.
> We apologise for the instability this may cause.

**Phronomy** is a Ruby AI agent framework for stateful Agents, Workflows, Tools,
context management, filtering, tracing, and multi-agent coordination. Large Language
Model (LLM) operations use `Phronomy::LLMAdapter`; the default backend uses
[RubyLLM](https://github.com/crmne/ruby_llm). Custom backends implement the
[SDK-independent LLM contract](docs/migrations/r8-unit6.md).
Tool declarations and argument validation belong to `Phronomy::Tool`, independently
of the selected LLM backend.

Phronomy is pre-1.0. Pin to a released gem version for production use rather than
tracking `main` directly.

## Core concepts

- **Agent** — stateful, persistence-backed LLM agent with canonical execution history.
- **Persistence** — shared atomic scopes with domain-owned Agent/Team stores and Workflow checkpoints.
- **Workflow** — state-machine-driven application workflow with task states, explicit events and wait states.
- **Tool / Capability** — callable application capability exposed to an Agent; application-defined Tools subclass `Phronomy::Tool::Base`.
- **Multi-Agent Handoff** — semantic Source-to-Target responsibility transfer with policy-bounded Context projection and persisted active responsibility and exact Target recovery within one Persistence domain.
- **EventLoop + FSMSession** — the framework control plane for logical lifecycle coordination.
- **OffloadPool** — bounded operating-system-thread execution boundary for synchronous work that must not run on EventLoop.
- **TaskResult** — the common thread-free completion handle returned by Phronomy asynchronous APIs, including OffloadPool-backed work.
- **TaskResult.completed / TaskResult.failed** — already-settled application results without starting execution.
- **TaskResult.map / flat_map / all_settled** — result transformation, asynchronous chaining and ordered all-settled observation.
- **Execution.run_async / run** — start application JOBs and join their final results under a whole-execution timeout and cancellation scope.
- **Blocking.call_async** — submits synchronous application work to the existing bounded OffloadPool without waiting for queue space.
- **Journal / Context Policy / Manifest** — canonical history plus per-LLM-call context selection.

See [Features and Application Programming Interface (API) stability](docs/features.md) for the full feature matrix.

The following application APIs are available as Beta in v0.30.0:

| API | Stability | Contract |
|---|---|---|
| `Phronomy::LLMAdapter::LMStudio` | Beta | Explicit known-output-error identification and bounded opt-in retry; [policy and evidence limits](docs/architecture/lm-studio-output-failures.md) |
| Agent `output_schema:`, `schema_delivery:`, `Agent::OutputError` and `OutputParser::JsonSchemaParser` | Beta | Agent returns validated immutable JSON or an explicit output failure; [contract and migration](docs/architecture/structured-output-and-scope.md) |
| Agent `transcript_messages` / `transcript_messages_async` | Beta | Read immutable conversation Message values with the same restoration rules as execution results; [reading conversation state](docs/getting-started.md) |
| `Phronomy::GeneratorVerifier`, its approval/lifetime operations and immutable `Result` with output-failure diagnostics | Beta | [Generation and structured-output contract](docs/architecture/structured-output-and-scope.md) |
| `Agent.open_scope`, `Agent::Scope`, `Agent::Base#unload_async / #unload!`, `AgentUnloadedError` and `Agent::ScopeCleanupError` | Beta | Runtime-bound ownership and safe release of idle Agent incarnations without changing saved history or closing the Store; [contract](docs/architecture/dx05-agent-scope.md) |
| `Workflow::Builder#task_state` and `WorkflowTaskResumeError` | Beta | State-entry-scoped Task completion, live cancellation and explicit restart rejection; [contract](docs/architecture/dx05-workflow-task-state.md) |
| `Phronomy::Integrations::OrderedEventDelivery` | Beta | Optional ordered delivery with bounded admission and explicit drain lifetime; [usage](docs/ordered-event-delivery.md) |
| `Phronomy::Error#code` and error constructor `code:` | Beta | Optional reason codes and bounded causes retained in saved failure diagnostics; [meaning and compatibility](docs/architecture/error-api-review.md) |
| `Phronomy::AgentNotFoundError#agent_id` | Beta | Identifies absence of the requested Agent root; referenced history and Content failures retain their own errors; [migration](docs/architecture/error-api-review.md) |
| `Phronomy::MultiAgent::TeamNotFoundError` and `TeamBusyError`, with `team_id` | Beta | Team-owned absence and busy errors; child Agent failures retain their Agent classification; [migration](docs/architecture/error-api-review.md) |
| `Phronomy::Embeddings::AuthenticationError` and `RateLimitError` | Beta | Embeddings-owned transport error subclasses retaining the provider cause; [migration](docs/architecture/error-api-review.md) |
| `Phronomy::Tracing::Base.trace_with` | Beta | Uses the tracer start/finish SPI, attempts finish once, and preserves a primary application error; [contract](docs/architecture/error-api-review.md) |

## Installation

Add Phronomy to your Gemfile:

```ruby
gem "phronomy"
```

Then run:

```bash
bundle install
```

Phronomy requires RubyLLM 2.0.x. The tested minimum HTTP stack is Faraday
2.14.4 and faraday-net_http 3.4.4; newer versions within their respective major
versions are allowed. Both floors are explicit: raising Faraday alone can still
resolve an old Net::HTTP adapter that loses HTTP status during streaming.
CI checks fresh resolution and this exact pair with MCP 1.0.0. These are verified
support floors, not a claim about the first upstream release containing a fix.
See the
[RubyLLM 2 and token-ownership migration](docs/architecture/rubyllm-2-token-ownership.md)
for removed input-budget overrides and the in-flight Tool-manifest upgrade boundary.

Configure RubyLLM with the provider credentials and transport policy required by
your application. The default adapter delegates transport retry and timeout policy
to RubyLLM. The explicitly selected LMStudio backend instead disables SDK retries
and can retry one narrowly recognized generated-format failure at most once;
see its [policy](docs/architecture/lm-studio-output-failures.md).

```ruby
RubyLLM.configure do |c|
  c.openai_api_key = ENV["OPENAI_API_KEY"]
  c.request_timeout = 120
  c.max_retries = 3
end
```

See [Getting started](docs/getting-started.md) for installation details, optional
dependencies, stateful Agent setup, streaming, and Workflow examples.

## Quick start

```ruby runnable
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

result = ResearchAgent.new.invoke("What happened in AI research this week?")
puts result[:output]
```

`Phronomy::Tool::Base` is the public base class for application-defined Tools.

For non-blocking top-level use, call `invoke_async` and keep the returned
`Phronomy::TaskResult`. Inside Phronomy lifecycle callbacks, do not block waiting for
another TaskResult; continue through explicit events instead.

```ruby
task = ResearchAgent.new.invoke_async("Research Ruby AI frameworks")
result = task.wait_result   # top-level/external caller only
```

Agent lifecycle events are bound to one live Agent Runtime incarnation.
Register `on_event:` (or the equivalent construction block) when the Agent
is created or loaded, then invoke it without a per-call listener:

```ruby
agent = ResearchAgent.new(
  on_event: ->(event) {
    puts event.type   # :done, :error, :tool_call, :tool_result, etc.
  }
)

task = agent.invoke_async("Research Ruby AI frameworks")
```

The same listener registration is available on `create` and `load`.
Public per-invocation `on_event:` / listener blocks are removed.

## Runtime model

Phronomy uses one completion model with two execution mechanisms:

```text
Runtime
├─ EventLoop
│  └─ FSMSession
│     ├─ Agent
│     ├─ Workflow
│     ├─ ToolInvocation
│     └─ MultiAgent fan-out
├─ OffloadPool
│  └─ synchronous off-EventLoop work
└─ EventLoop-driven timers

EventLoop / FSMSession ─┐
                       ├─> TaskResult = completion handle
OffloadPool ────────────┘
```

Logical waiting remains in EventLoop/FSMSession state. Synchronous work that
would block EventLoop uses the bounded OffloadPool. OffloadPool-specific queue,
worker, timeout, and abandonment state remains private runtime machinery; callers
observe completion through `Phronomy::TaskResult`. See
[Runtime and concurrency](docs/runtime-and-concurrency.md) for the detailed
contracts, timeout/cancellation semantics, metrics, and callback rules.

## Documentation

- [Getting started](docs/getting-started.md) — installation, RubyLLM setup, Agent/Workflow basics, persistence, streaming.
- [Application recipes](docs/application-recipes.md) — complete persistence, streaming, and Workflow examples, including explicit failure handling.
- [Features and API stability](docs/features.md) — public feature matrix and stability labels.
- [Architecture](docs/architecture.md) — canonical current explanatory architecture entry and authority navigation.
- [Runtime and concurrency](docs/runtime-and-concurrency.md) — EventLoop, FSMSession, TaskResult, OffloadPool, cancellation, observability.
- [Result composition and Execution](docs/async-composition.md) — application JOBs, map/flat_map, fan-in snapshots, context ownership and migration.
- [MCP client](docs/mcp-client.md) — Model Context Protocol (MCP) integration and supported schema subset.
- [Migration from 0.15-era APIs](docs/migrations/0.15.md).
- [0.16 cleanup migration](docs/migrations/0.16.md).
- [r8 persistence boundary migration](docs/architecture/r8-unit3.md) — domain stores, shared scopes, and removed facade APIs.
- [Persistence failure contract migration](docs/migrations/persistence-failure-contracts.md) — domain rescue clauses and unchanged raw backend errors.
- [0.19 unified Persistence migration](docs/migrations/0.19.md).
- [0.22 semantic Multi-Agent Handoff migration](docs/migrations/0.22.md).
- [Architecture Decision Records](docs/decisions/) — design rationale and superseding decisions.
- [CHANGELOG](CHANGELOG.md) — current development and recent release history.
- [Changelog archive: 0.14.0 and earlier](docs/changelog/0.14-and-earlier.md).

## Examples

Runnable examples covering major features are maintained in the
[phronomy-examples](https://github.com/Raizo-TCS/phronomy-examples) repository.

## Development

After checking out the repository:

```bash
bin/setup
bundle exec rspec spec/phronomy
```

Integration tests can be run with:

```bash
bundle exec rspec spec/integration --tag integration
```

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security and privacy

- Provider credentials are handled by RubyLLM; Phronomy does not persist LLM API keys.
- Trace payloads are redacted by default when `trace_pii: false`.
- Tools and MCP servers are external trust boundaries; apply approval and application-specific policy to side-effecting capabilities.
- `PromptInjectionFilter` is a useful baseline, not a complete untrusted-input defence.
- Report vulnerabilities privately through GitHub Security Advisories rather than a public issue.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
