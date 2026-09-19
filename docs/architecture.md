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

The first definition in this group is `Phronomy::Error`, the shared base
exception. Its only superclass is Ruby's `StandardError`. Zeitwerk collapses
`common/`, preserving the canonical public name without introducing a
`Phronomy::Common` namespace. Other error types and global configuration have
not been regrouped by this change. See
[ADR-037](decisions/037-common-definition-ownership.md).

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
