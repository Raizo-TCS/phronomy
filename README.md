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

The following table describes application APIs in v0.37.0 and the current
development version. Entries marked Unreleased are not available in v0.37.0.
The public persistence resource catalogs are available starting with v0.35.0.
The sharing, Tool composition and Context budgeting operations remain
Experimental; their introduction version is shown below.
Worker hosting and completed parent/child release require v0.32.0 or later.
Review the [0.31 migration notes](docs/migrations/0.31.md) before upgrading
persistent applications or custom Agent Tool subclasses.

The v0.34.0 cleanup removes obsolete entry points. Use
`EventLoopReentrancyError` for EventLoop reentrancy failures and
`Runtime#shutdown`'s `cleanup_complete?` result predicate for resource release;
`clean?` additionally requires a graceful shutdown. See the
[cleanup migration](docs/migrations/cleanup-audit.md) before upgrading to v0.34.0.
The [legacy-format cleanup](docs/migrations/legacy-format-removal.md) separately
retires old data-conversion entry points and read fallbacks without changing
the current saved representation.

| API | Stability | Contract |
|---|---|---|
| `PersistenceComposition.resources` and `.agent_resources` | Beta (since v0.35.0) | Supply canonical frozen resource catalogs to an application-selected backend for `.build(backend:)` or `.agent(backend:)`, without creating a backend, stores or Runtime. [Backend catalog](docs/persistence-backends.md#supplying-a-backend-catalog) |
| `Persistence::Migration::InitialFormatMigration` | Removed (v0.34.0) | The pre-S3 conversion API is retired without a replacement. Current domain codecs and the separate Unit4 snapshot migration remain. [Legacy-format cleanup](docs/migrations/legacy-format-removal.md) |
| `Context::ContextPolicyInput#input_token_limit / #with_input_token_limit` and protected `ContextPolicy#estimate_tokens` | Experimental (since v0.33.0) | Inspect and constrain selection budgets and estimate candidate content through Context-owned operations. [Policy budgeting](docs/context-policy-budgeting.md) |
| `Agent::Base.with_tools(definitions, id:, version:)` | Experimental (since v0.33.0) | Derive an Agent class with a complete replacement Tool map and explicit definition identity while preserving Phronomy authoring settings and filters. Orchestrator derivation also preserves native subagent registrations for retained child Tools, including their aliases. [Tool composition](docs/shared-state-sharing.md#deriving-an-agent-with-a-complete-tool-set) |
| `MultiAgent::SharedState.sharing(provider, id:, version:)`, `SharedState::Binding` and `SharedState::MemberLifecycleError` | Experimental (since v0.33.0) | Sequential coordination releases its terminal member Agents in both default and custom modes; an optional invocation-scoped provider supplies application-owned data and Tools. [Sharing and member lifetime contract](docs/shared-state-sharing.md) |
| `Tool::Base#approval_display(arguments:, facts:)` | Beta (since v0.33.0) | The Tool selects the arguments and derived facts a person can see in an approval request. [Approval display](docs/runtime-and-concurrency.md#tool-approval-display) |
| `Runtime#shutdown` result predicates `cleanup_complete?` and `clean?` | Beta | Check resource release with `cleanup_complete?`; `clean?` additionally requires a graceful shutdown. The obsolete `success?` alias is removed in v0.34.0. [Cleanup migration](docs/migrations/cleanup-audit.md#runtime-cleanup-completion) |
| `Phronomy::EventLoopReentrancyError` | Beta | Raised when a synchronous operation would block the EventLoop control thread. The obsolete `SchedulerReentrancyError` subclass is removed in v0.34.0. [Cleanup migration](docs/migrations/cleanup-audit.md#eventloop-reentrancy-errors) |
| `Phronomy::LLMAdapter::LMStudio` | Beta | Explicit known-output-error identification and bounded opt-in retry; [policy and evidence limits](docs/architecture/lm-studio-output-failures.md) |
| Agent `output_schema:`, `schema_delivery:`, `Agent::OutputError` and `OutputParser::JsonSchemaParser` | Beta | Agent returns validated immutable JSON or an explicit output failure; [contract and migration](docs/architecture/structured-output-and-scope.md) |
| Agent `start_reserved_async`, `resume_async` and `resume` | Beta (behavior changed in v0.37.0) | Return the confirmed execution result, including `status: :failed` and saved `OutputError` diagnostics. Errors in starting, resuming or observing the execution remain operation failures; [exact execution results](docs/architecture/structured-output-and-scope.md#exact-execution-results) |
| `Agent::ExecutionRejectedError` and Team rejection handling | Beta (Unreleased) | Distinguish reserved-start validation rejection from uncertain execution outcomes. Team validates durable input before admission and records a confirmed child-start rejection as its own failure after a guarded absence check; [rejection contract](docs/architecture/team-admission-rejection.md) |
| `MultiAgent::TeamCoordinator#invoke / #stream / #resume / #result` | Beta | Terminal runs retire internally owned child Agents after physical work completes; saved outcomes remain authoritative. `result` stays read-only and terminal `resume` can retry failed retirement. Automatic retirement is Unreleased; [child lifetime](docs/architecture/team-child-retirement.md) |
| `MultiAgent::TeamCancellationDeliveryError` | Beta (Unreleased) | Exact Team/run identities for unresolved token-originated cancellation delivery. Retained intent can be retried with the same run's `resume` or `cancel`; [control delivery and lifetime](docs/architecture/team-cancellation-delivery.md). |
| Agent `pending_terminal_recovery(execution_id:)`, `reconcile_terminal[_async](recovery:)`, `retry_terminal[_async](recovery:)`, `Agent::TerminalRecovery`, `Agent::TerminalRecoveryResult` and `Agent::TerminalRecoveryError` | Unreleased | Observe retained terminal saves on the original running or draining Runtime. Reconciliation performs no persistence writes; explicit retry saves captured records without replaying application work. Saved outcome, owner application and release remain separate; no stopped-owner or process-crash recovery. [Recovery contract](docs/architecture/agent-terminal-recovery.md) |
| Agent `retry_terminal_submission[_async](recovery:)` and `Agent::TerminalRecoveryResult#submission_state` | Unreleased | Explicitly resubmit terminal work only after the execution mechanism proves it was not admitted. Validation and encoding may run for the first time; provider/Tool work is not repeated. Captured-write retry stays separate. [Submission recovery](docs/architecture/agent-terminal-submission-recovery.md) |
| Agent `pending_outcome_recovery(execution_id:)`, `reconcile_outcome[_async](recovery:)`, `retry_outcome[_async](recovery:)`, `retry_outcome_submission[_async](recovery:)`, `Agent::OutcomeRecovery`, `Agent::OutcomeRecoveryResult` and `Agent::OutcomeRecoveryError` | Unreleased | Recover a native parent's captured final, coordination-wait or approval-wait save through its original owner. Readback and explicit captured-write retry remain separate; `saved_outcome` identifies the saved kind. Releasing recovery custody does not finish a waiting job. Existing terminal recovery remains actual-final only; no process-loss takeover. [Native outcome contract](docs/architecture/native-parent-outcome-recovery.md) |
| Agent `pending_approval_recovery(execution_id:)`, `reconcile_approval[_async](recovery:)`, `Agent::ApprovalRecovery`, `Agent::ApprovalRecoveryResult` and `Agent::ApprovalRecoveryError` | Unreleased | Read retained supported standalone, child/restored and native-parent approval decisions on the original running or draining Runtime without retrying approval writes. Confirmed pre-state restores the same wait; confirmed post-state can start the authorized continuation with a fresh execution observation. Native decisions require fresh child authority. Approval worker completion does not mean execution completion; no stopped-owner or process-crash recovery. [Approval recovery](docs/architecture/agent-approval-recovery.md), [native decisions](docs/architecture/native-parent-outcome-recovery.md#recover-the-native-parents-own-approval-decision) |
| Agent `pending_dispatch_recovery(execution_id:)`, `reconcile_dispatch[_async](recovery:)`, `retry_dispatch[_async](recovery:)`, `Agent::DispatchRecovery`, `Agent::DispatchRecoveryResult` and `Agent::DispatchRecoveryError` | Unreleased | Reconcile retained pre-dispatch preparation through the original live Agent. Explicit retry writes only the captured persistence proposal; preparation and external work are not replayed. Saved permission, continuation handoff and physical completion remain separate; includes bounded [native parent dispatch](docs/architecture/native-parent-dispatch-recovery.md) with fresh child-authority checks. No stopped-owner or process-crash recovery. [Dispatch recovery](docs/architecture/agent-dispatch-recovery.md) |
| Agent `pending_initial_preparation_recovery`, `reconcile_initial_preparation[_async](recovery:)`, `retry_initial_preparation[_async](recovery:)`, `Agent::InitialPreparationRecovery`, `Agent::InitialPreparationRecoveryResult` and `Agent::InitialPreparationRecoveryError` | Unreleased | Recover admission, the first manifest or preparation failure through one original initial owner. Confirmed admission may start preparation once; explicit retry repeats captured writes only. Original controls survive observer failure, and same-execution observation is separate from custody release. Standalone and framework reservations are supported; opaque admission uncertainty and stopped-owner recovery remain outside this contract. [Initial preparation recovery](docs/architecture/initial-preparation-recovery.md) |
| `MultiAgent::HandoffRunner#resume(execution_id, config: {})` | Unreleased | Continue the exact recorded Handoff chain after explicit Agent dispatch recovery. Terminal history returns durable execution fields plus `agent` without starting another turn; unresolved retained dispatch requires the original Agent recovery API. Ordinary `invoke` remains turn entry. [Handoff recovery](docs/architecture/handoff-dispatch-recovery.md) |
| Agent `transcript_messages` / `transcript_messages_async` | Beta | Read immutable conversation Message values with the same restoration rules as execution results; [reading conversation state](docs/getting-started.md) |
| `Phronomy::GeneratorVerifier`, its approval/lifetime operations and immutable `Result` with output-failure diagnostics | Beta | [Generation and structured-output contract](docs/architecture/structured-output-and-scope.md) |
| `Agent.open_scope`, `Agent::Scope`, `Agent::Base#unload_async / #unload!`, `AgentUnloadedError` and `Agent::ScopeCleanupError` | Beta | Runtime-bound ownership and safe release of idle Agent incarnations without changing saved history or closing the Store; [contract](docs/architecture/dx05-agent-scope.md) |
| `Agent::Base#start_hosted`, `Agent::HostedInvocation`, `Agent::ApprovalWait` and `Agent::Store#standalone_approval_wait` | Beta | Added in v0.32.0. Detach an exclusively owned standalone Agent at its first committed approval wait, then restore the same execution in another process; delivery claims and worker fencing remain application responsibilities; [contract](docs/runtime-and-concurrency.md#hosting-a-standalone-agent-through-approval) |
| `Agent::HostedInvocation#detach!(execution_id:, approval_request_id:)` | Beta | Added in v0.32.0. Release an exclusively owned Orchestrator and its single direct subagent at the child's approval wait. A second worker can resume both saved executions while the first worker handles other requests. [Contract](docs/runtime-and-concurrency.md#hosting-an-orchestrator-through-a-child-approval) |
| `MultiAgent::Orchestrator#approve_hosted_child` | Beta | Added in v0.32.0. Answer the current approval on a restored direct child. The returned handle can release the pair again if that child requests another approval during the same execution. [Contract](docs/runtime-and-concurrency.md#hosting-an-orchestrator-through-a-child-approval) |
| `Agent::ApprovalRecoveryResult#hosted_invocation` and child/restored approval recovery | Unreleased | Reconcile the original decision on a direct correlated child or restored wait. A recovered hosted continuation can return an independent handle for its next approval detach; original failed observations remain closed. [Child approval recovery](docs/architecture/agent-child-approval-recovery.md) |
| `MultiAgent::Orchestrator#unload_with_completed_child!` | Beta | Added in v0.32.0. Release local owners after a direct child result has been imported and the parent has finished. Unreleased: a separate acknowledgement by the terminal parent can also establish child custody. The saved executions, transcripts and coordination history remain available. [Contract](docs/runtime-and-concurrency.md#releasing-a-completed-orchestrator-and-child) |
| `MultiAgent::Orchestrator::ChildCleanupError` | Beta (since v0.36.0) | Retains exact child owners and causes when direct dispatch cannot safely release children whose results are not returned. Ordinary successful results keep their existing Agent reuse contract. [Direct-child lifetime](docs/async-composition.md#direct-orchestrator-children) |
| `Tools::Agent.from_agent` and generated Tool `call_async` | Beta | Fresh children inherit application context and cancellation/deadline controls while owning their own execution wiring. Parent-binding isolation is Unreleased; arguments and result formats are unchanged. [Child invocation context](docs/architecture/agent-tool-child-lifetime.md#child-invocation-context) |
| `Tools::Agent::CleanupError` | Beta | Added in v0.31.0. Preserves the child, result and failure causes when safe release fails; retry `child_agent.unload_async` for release only; [contract](docs/architecture/agent-tool-child-lifetime.md) |
| `Workflow#send_saved_event` | Beta | Added in v0.32.0. Deliver an event to a specific revision of a persisted Workflow wait; [contract](docs/runtime-and-concurrency.md#delivering-an-event-to-a-saved-workflow-wait) |
| `Workflow#pending_terminal_recovery / #reconcile_terminal_async / #reconcile_terminal` and `WorkflowTerminalRecoveryError` | Beta (Unreleased) | Explicit observation of retained terminal saves through the original running or draining Runtime; persistence, owner application and release remain separate. No stopped-owner takeover; [recovery contract](docs/architecture/workflow-terminal-reconciliation.md) |
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
- [0.31 persistence and Agent lifetime migration](docs/migrations/0.31.md).
- [0.34 cleanup migration](docs/migrations/cleanup-audit.md) — replacement entry points and retained public operations.
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
