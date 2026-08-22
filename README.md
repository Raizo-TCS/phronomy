# Phronomy

> **⚠️ Development Notice**
> This project is primarily developed and maintained by **AI coding agents**.
> As a result, `main` receives frequent, large, and unannounced changes.
> External contributors should expect significant churn and potential conflicts at any time.
> We apologise for the instability this may cause.

**Phronomy** is a Ruby AI agent framework for stateful Agents, Workflows, Tools,
context management, filtering, tracing, and multi-agent coordination. Large Language
Model (LLM) access is provided through [RubyLLM](https://github.com/crmne/ruby_llm).

Phronomy is pre-1.0. Pin to a released gem version for production use rather than
tracking `main` directly.

## Core concepts

- **Agent** — stateful, persistence-backed LLM agent with canonical execution history.
- **Persistence** — unified durable backend for Agent state and Workflow `workflow_states`.
- **Workflow** — state-machine-driven application workflow with explicit events and wait states.
- **Tool / Capability** — callable application capability exposed to an Agent; application-defined Tools subclass `Phronomy::Tool::Base`.
- **Multi-Agent Handoff** — semantic Source-to-Target responsibility transfer with policy-bounded Context projection and Runtime-local active-Agent continuity.
- **EventLoop + FSMSession** — the framework control plane for logical lifecycle coordination.
- **OffloadPool** — bounded operating-system-thread execution boundary for synchronous work that must not run on EventLoop.
- **Task** — the common thread-free completion handle returned by Phronomy asynchronous APIs, including OffloadPool-backed work.
- **Journal / Context Policy / Manifest** — canonical history plus per-LLM-call context selection.

See [Features and Application Programming Interface (API) stability](docs/features.md) for the full feature matrix.

## Installation

Add Phronomy to your Gemfile:

```ruby
gem "phronomy"
```

Then run:

```bash
bundle install
```

Configure RubyLLM with the provider credentials and transport policy required by
your application. Phronomy does not add another LLM transport retry/timeout layer.

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

`Phronomy::Tool::Base` is the public authoring name for the existing Tool base
class. The legacy `Phronomy::Agent::Context::Capability::Base` constant remains
valid for compatibility.

For non-blocking top-level use, call `invoke_async` and keep the returned
`Phronomy::Task`. Inside Phronomy lifecycle callbacks, do not block waiting for
another Task; continue through explicit events instead.

```ruby
task = ResearchAgent.new.invoke_async("Research Ruby AI frameworks")
result = task.wait_result   # top-level/external caller only
```

A block listener receives Agent lifecycle events and is equivalent to `on_event:`:

```ruby
task = ResearchAgent.new.invoke_async("Research Ruby AI frameworks") do |event|
  puts event.type   # :done, :error, :tool_call, :tool_result, etc.
end

# on_event: keyword form is also accepted and behaves identically
task = ResearchAgent.new.invoke_async("Research Ruby AI frameworks", on_event: listener)
```

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
                       ├─> Task = completion handle
OffloadPool ────────────┘
```

Logical waiting remains in EventLoop/FSMSession state. Synchronous work that
would block EventLoop uses the bounded OffloadPool. OffloadPool-specific queue,
worker, timeout, and abandonment state remains private runtime machinery; callers
observe completion through `Phronomy::Task`. See
[Runtime and concurrency](docs/runtime-and-concurrency.md) for the detailed
contracts, timeout/cancellation semantics, metrics, and callback rules.

## Documentation

- [Getting started](docs/getting-started.md) — installation, RubyLLM setup, Agent/Workflow basics, persistence, streaming.
- [Features and API stability](docs/features.md) — public feature matrix and stability labels.
- [Runtime and concurrency](docs/runtime-and-concurrency.md) — EventLoop, FSMSession, Task, OffloadPool, cancellation, observability.
- [MCP client](docs/mcp-client.md) — Model Context Protocol (MCP) integration and supported schema subset.
- [Migration from 0.15-era APIs](docs/migrations/0.15.md).
- [0.16 cleanup migration](docs/migrations/0.16.md).
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
