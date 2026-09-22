# Phronomy Architecture

This is the canonical entry point for Phronomy's **current explanatory
architecture**.

Phronomy deliberately separates architecture intent, implementation reality,
public contracts, and historical design material:

- [Architecture Decision Records](decisions/README.md) are the normative
  decision history and authority for Accepted, non-superseded decisions.
- The documents linked below explain the reconciled current system.
- Source/runtime behavior defines current implementation reality.
- Public APIs and extension SPIs are composite contracts established by runtime
  behavior, `@api` classification, formal API documentation, and explicit
  compatibility/contract tests.
- RBS represents an already-established contract; it does not create one.
- Historical and archived designs live under `docs/archive/design/` and are
  non-normative.

There is no universal "newest artifact wins" rule. When architecture intent,
public contract, and implementation reality disagree, the discrepancy must be
reviewed explicitly rather than resolved by recency.

## Design principles

These are design heuristics for new and revised architecture. They do not
override an Accepted ADR, an established public/extension contract, or an
explicit compatibility decision.

- **Ruby-idiomatic application surface.** Prefer Ruby-idiomatic Application APIs
  and DSLs over mechanical translation of conventions from another language or
  framework.
- **Progressive adoption.** Keep Phronomy building blocks independently
  adoptable where their semantics allow it. Applications should be able to
  introduce Agent, Tool, Persistence, Workflow, Multi-Agent, and related
  capabilities according to need rather than being forced through the legacy
  Chain/Memory maturity-level model. This does not promise that a subsystem has
  no explicit dependencies required by its own contract.
- **Small and explicit core dependency surface.** Prefer a small and explicit
  core dependency surface. This is an engineering preference, not a hard invariant:
  dependency minimization must not weaken accepted durability,
  ownership, security-boundary, or extension contracts.

## Responsibility groups and dependency graphs

Dependency views describe a directed graph of responsibility groups, not a
tree or a single pipeline. Several distinct groups may share one horizontal
band. A band's height expresses a proposed abstraction level; it does not imply
that its groups are independent or that every valid dependency points down.

Assess each dependency by the referenced contract and its owner. Shared value
types, extension contracts, and collaboration within a component can justify
dependencies between groups. A directory containing both shared definitions and
concrete orchestration must be examined by responsibility before assigning it a
single position. Cycles and upward arrows are review evidence, not defect counts.

The FSM terminal marker illustrates this distinction. `FSMProtocol::FINISH`
owns the internal `:__end__` marker used by the session and Workflow compilers.
The public Workflow DSL continues to use `:__finish__`. The execution session
and phase compiler do not depend on `WorkflowRunner` for this shared vocabulary;
the Workflow builder still legitimately creates its runner.

Context Policy and hook contracts provide another example. The shared values,
Manifest representation, and Plan validation live in `agent/context_contract/`,
separately from concrete policies and Agent execution. Zeitwerk collapses that
directory to preserve the existing `Phronomy::Agent` constants. A Policy's
dependency on those contracts does not make it depend on Agent execution. See
[ADR-036](decisions/036-context-contract-ownership.md).

### Common definitions

`common/` owns general definitions shared across the framework that do not
belong to a particular feature. They must not depend on concrete Agent,
Workflow, Runtime, or other feature implementations. Being used in several
places, or inheriting a common base class, does not by itself make a definition
common; feature-owned contracts remain with their owners.

This group contains `Phronomy::Error`, `Phronomy::ConfigurationError`,
`Phronomy::CanonicalJSON`, and `Phronomy::Values::Immutable`. Zeitwerk collapses
`common/`, preserving these canonical names without introducing a
`Phronomy::Common` namespace. Other exceptions belong to their feature
contracts. `configuration/` owns settings and scalar defaults. The concrete
adapter and tracer defaults are selected in `runtime_composition/`, which binds
fresh-instance factories consumed by `Configuration.new`. This keeps concrete
feature selection outside settings while preserving application behavior.
Application Runtime reset and configuration replacement are also coordinated in
`runtime_composition/`, separately from configuration access and Engine mechanics.
See [ADR-039](decisions/039-runtime-configuration-lifecycle-ownership.md) and
[ADR-040](decisions/040-configuration-default-composition.md).
See [ADR-037](decisions/037-common-definition-ownership.md) and
[ADR-038](decisions/038-responsibility-based-source-layout.md).

### Source placement and loading

`lib/phronomy.rb` is the application loading entry point. Internal production
files must not require it. Feature implementations and contracts live in their
responsibility directories; the direct root contains only `version.rb` and the
small namespace/loading files enumerated in ADR-038.
The separately documented external backend-test entry
`phronomy/testing/persistence_contract` retains its existing opt-in loading
contract and is excluded from production automatic loading.

Engine owns Event, Execution composition and its outcome exceptions, and the
synchronous FSM callback exceptions. Recovery owns shared rehydration
requirements. Workflow implementation lives under `workflow/execution/`;
Agent namespace/event loading lives under `agent/api/`, separately from the shared
Agent lifecycle exceptions in `agent/lifecycle_contract/`. LLM values and
call-boundary exceptions live under `llm_contract/`.

Agent consumes its private fresh-Persistence factory only when neither an
explicit instance nor a configured instance is available. Concrete selection
and binding live in `runtime_composition/agent_defaults.rb`. The one-shot
`Agent.run_once` method is defined in `agent/composition/run_once.rb`, because it
explicitly composes Agent and fresh ephemeral Persistence on every call.
The application entry loads both composition files; Agent execution and
namespace loading do not delegate upward to them. See
[ADR-044](decisions/044-agent-default-and-one-shot-composition.md).

Types excluded from authorization worker inputs declare the internal,
methodless `Concurrency::WorkerInputRestricted` contract at their own
definitions. ToolInvocation checks that execution-boundary contract rather
than concrete Workflow types. The original restriction set and opaque
application-value behavior are preserved; see
[ADR-045](decisions/045-worker-input-restriction-ownership.md).

Agent implementation files are grouped into lifecycle, execution, Tool execution,
context assembly, journal, Handoff and recovery directories. These directories
are collapsed, so existing Agent constant names remain unchanged. Journal encoding,
saved context reads and live invocation restoration have separate internal owners;
transaction and EventLoop state decisions remain with their callers. See
[ADR-046](decisions/046-agent-responsibility-layout-and-shared-records.md).

Recovery hands semantic continuation commands to the execution owner through
its EventLoop delivery boundary. The owner checks current identity, revision
and session state before applying them. `Agent::ExecutionSessionRunner` shares
ordinary and recovered Agent/Tool session registration and reports completion
back to the same coordinator; operation workers now own terminal persistence
under its EventLoop result authority (ADR-051 below).
See [ADR-047](decisions/047-recovered-execution-continuation-contract.md).

`Agent::DispatchPreparation` owns Provider/Tool dispatch prerequisites and their
operation-specific readback. ExecutionCoordinator captures and submits inputs,
then validates/applies results on EventLoop before dispatch. The worker's Provider
entry separates record encoding, application ContextPolicy, prerequisite commit
and post-commit materialization without changing transaction/rescue boundaries.
Its input/result types are worker-owned; existing Coordinator constant paths are
internal aliases, with changed canonical Ruby names. See
[ADR-048](decisions/048-dispatch-preparation-worker-ownership.md).

`Agent::InitialPreparation` owns initial durable admission, Context preparation,
preparation failure persistence and replay from saved preparing inputs. Ordinary
start and recovery share the admitted-preparation steps; Runtime admission,
result validation, live-state apply and session delivery remain on EventLoop.
The known failure base advances only after a successful commit response.
`Agent::ExecutionFailure` shares the existing pure failure classification with
terminal persistence; it does not own transactions or delivery. See
[ADR-049](decisions/049-initial-preparation-worker-ownership.md).

`Agent::ApprovalResumeCommit` persists approval decisions with operation-owned
Tool recovery snapshots. Coordinator validates the suspended owner and approval
request before copying canonical snapshot values into the immutable Command;
there is no shared snapshot lookup. The worker validates the target, stages
recovery facts and commits decision/Execution/Root together. EventLoop retains
admission, stale-result checks, live-state application and session resumption.
An uncertain commit still requires recovery; it is not retried or treated as a
confirmed resume. Internal Coordinator type aliases remain, with changed
canonical names and an added Command snapshot field. See
[ADR-050](decisions/050-approval-resume-snapshot-and-commit-ownership.md).

`Agent::ExecutionOutcomeCommitter` owns ordinary completion, failure, suspension
and child waiting; `Agent::HandoffOutcomeCommitter` adds atomic Source transfer.
The Handoff Coordinator now only selects its worker. Transaction boundaries,
operation-specific readback and Handoff selection precedence remain unchanged.
Coordinator retains quiescence, submission, stale-result validation, live-state
application, admission and Task/listener delivery. Command/view/outcome types are
worker-owned with internal Coordinator aliases and changed canonical Ruby names.
See [ADR-051](decisions/051-execution-outcome-worker-ownership.md).

The remaining execution owner expresses result handling as validation, committed
state installation, and continuation or delivery. Private methods keep these
steps in Coordinator; they introduce neither another owner nor shared per-operation
fields. The operation-specific authority checks and outer rescue boundaries stay
at the result entry points. Start/resume admission and submission flags stay in
the same methods as their cleanup decisions.

| Owner entry | Purpose-level steps |
| --- | --- |
| Initial preparation recovery result | Validate preparing owner; restart the prepared session or settle its saved failure; complete the load observer |
| Approval resume result | Validate suspended revision; install committed state and waiter; observe the task; resume the FSM |
| Terminal result | Validate revision/session; handle commit uncertainty; apply state and acknowledge the snapshot; deliver the selected outcome |

Terminal delivery releases ownership before notifying completed/failed/Handoff
observers, then settles Tasks. Suspension keeps ordinary Tasks pending. Ordinary
commit uncertainty keeps recovery admission and pending waiters; coordination
errors retain their separate release-and-fail behavior. Session registration
failure during preparation recovery still terminalizes without a live session;
trace/resume failure still uses the newly installed execution revision.
This is an internal readability refinement of ADR-024/047/051, not a change to
persistence, recovery guarantees or public interfaces.

Selected nested Zeitwerk roots retain existing top-level Phronomy constants
without changing the enclosing feature's existing nested constants. For
example, `Phronomy::WorkflowContext` and `Phronomy::WorkflowRunner` coexist with
`Phronomy::Workflow::Persistence`. Workflow remains a class and its source
file lives beside its implementation. These moves do not introduce aliases or
a new public API for requiring arbitrary internal paths.

The application loader explicitly preserves Workflow recovery installation;
the Agent entry explicitly preserves Agent lifecycle extension installation.
Configuration accessors now live beside Configuration, rather than inside the
loader. Configuration constructs fresh components through internally bound
factories; composition selects their concrete types. Static source-reference
graphs do not follow these injected calls. LLMAdapter's async bridge still uses
Runtime, and other dependency cycles remain.

Agent and Team implement their identity registries in `agent/` and
`multi_agent/`. Runtime strongly retains one of each when registered, using only
its generic shutdown participant contract. Feature code reserves identities,
handles feature exceptions, and detaches owners after completed cleanup.
See [ADR-041](decisions/041-feature-owned-identity-registries.md).

Agent and Workflow also own their distinct execution registries. EventLoop
retains them through Engine's internal `ExecutionReceiver` contract, dispatches
queued messages and combines generic session/delivery counts with their idle
predicates. Normal mutation remains on the EventLoop thread; only final
invalidation after join runs on the management thread. EventLoop has no Agent
or Workflow dispatch branch. See
[ADR-042](decisions/042-feature-owned-execution-state.md).

## Current architecture

| Area | Current document |
|---|---|
| Agent state, identity, ownership, and Context authority | [Agent Context](architecture/agent-context.md) |
| Per-LLM-call Context Policy and Manifest construction | [Context Management](architecture/context-management.md) |
| Journal-backed Knowledge and retrieval integration | [Knowledge and RAG](architecture/knowledge-and-rag.md) |
| Filter, Context trust policy, approval, and isolation boundaries | [Security Boundaries](architecture/security-boundaries.md) |
| Automatic logical-operation tracing and custom tracer SPI | [Tracing](architecture/tracing.md) |
| Durable Agent-domain responsibility transfer | [Multi-Agent Handoff](architecture/multi-agent-handoff.md) |
| Durable state, Runtime ownership, recovery, and codec boundaries | [Persistence](architecture/persistence.md) |
| Request-scoped pre-Manifest customization | [before_llm_input](architecture/before-llm-input.md) |
| Removed Agent Context / Memory architectures that must not return | [Removed Agent Context Architecture](architecture/removed/agent-context.md) |

Runtime execution mechanics are also documented in
[Runtime and concurrency](runtime-and-concurrency.md), and the custom Persistence
Backend SPI is documented in
[Persistence backends](persistence-backends.md).

## Authority and lifecycle

Current explanatory architecture documents are maintained to agree with the
current reconciled repository. They are not substitutes for ADR rationale.

Non-current material is split by lifecycle:

```text
docs/archive/design/historical/
  design snapshots that preserve historical architecture context

docs/archive/design/archived/
  obsolete or removed designs retained for historical reference
```

Archived/historical content may intentionally contain removed APIs and concepts.
It must not be used as a current implementation or compatibility contract.

The old `spec/design/` documentation location is not part of the current
documentation architecture.

Durable multi-agent coordination is described by [ADR-029](decisions/029-semantic-completion-and-application-effect-boundary.md),
[ADR-030](decisions/030-agent-handoff-domain-and-durable-responsibility.md) and
[ADR-031](decisions/031-durable-multi-agent-coordination.md).
TeamExecution is a purpose-specific CAS authority delegating coordinator/workers
to ordinary Agents, with no Team FSMSession or second Workflow engine.
Static subagent reservation lives in the existing parent AgentExecution metadata.
