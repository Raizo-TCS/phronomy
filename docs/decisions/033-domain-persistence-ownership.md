# 033: Own persistence rules within each domain

- Status: Amended
- Date: 2026-09-18
- Error boundary refined by: [043-storage-execution-constraint-notifications](043-storage-execution-constraint-notifications.md)
- Refines: [032-storage-backend-composition](032-storage-backend-composition.md)

## Context

ADR-032 separated raw storage from domain persistence, but the common-looking
`persistence/` directory still collected Agent, Team, and Workflow schemas and
repository facades. Moving that directory to an upper band in a dependency
diagram described its contents; it did not establish suitable domain ownership.
The public Persistence entry point also contained domain-specific result queries.

## Decision

1. `agent/persistence/` owns AgentRoot, Journal, AgentExecution, and Handoff
   codecs/repositories and Agent/Handoff result queries.
2. `multi_agent/persistence/` owns TeamRoot and TeamExecution codecs/repositories
   and Team result queries. Team persistence can be used over a raw backend
   without loading Agent implementation or the combined Persistence service.
3. `workflow/persistence/` owns the Workflow record schema, normalization rules,
   and state repository. Workflow symbol normalization remains specific to that
   domain; other codecs do not adopt it implicitly.
4. `Storage::RecordCodec` contains shared record-envelope and scalar validation.
   Domain codecs extend it; it neither selects nor imports a domain codec.
   These helpers and domain components are private implementation, not new SPI.
5. `PersistenceComposition::Repositories` explicitly assembles the seven domain
   repository wrappers and the existing ContentStore from one raw storage view.
   The public `Phronomy::Persistence` service remains the compatible entry point.
   It delegates queries and retains the Runtime observation-thread guard.
   Each view creates and caches domain wrappers on first use, under one lock,
   so Agent-only use does not load Team or Workflow implementations.
6. Conversion remains inside `backend.transaction`. Root and transaction paths
   use the same builder. Reusing the root view when the backend yields itself
   retains the existing repository identity and fault-injection behavior.
7. Delete the private combined `Persistence::DurableCodec` and
   `Persistence::RepositoryFacades`; do not preserve a second owner through
   compatibility aliases. Explicit historical migration keeps its public API
   and calls the new domain codecs.

InMemory, SQLite, and PostgreSQL are all concrete implementations of the common
Backend contract. Domain repository wrappers are consumers of that contract;
they do not introduce a second physical transaction boundary.

## Preserved contracts and limits

Public Persistence methods, Backend SPI, eight repository accessors, IDs,
revisions/positions, active constraints, physical SQL schemas, record types,
format versions, and payload schemas are unchanged. Existing SQL backends need
no source migration for this ownership change. The public result-reader dispatch
and observation guard remain in the public entry point.

Atomic durable-state transitions and rollback remain CONDITIONAL on a conforming
backend for F0. Commit-outcome certainty under F1 is not added. F4 restart
readability depends on retained confirmed data; InMemory is not disk retention.
X0 effects remain outside storage transactions.

The raw `Storage::Repositories` still names eight Phronomy record repositories and
an Agent watermark operation. This is an explicit intermediate state, not a claim
that the framework contract is domain-neutral. Contract generalization and naming
of the final common persistence framework are deferred to the staged plan below.

## Validation

Existing record-schema, backend conformance, optimistic conflict, recovery,
Handoff, Team, Workflow, and public compatibility tests remain required. A
separate-process boundary test uses Team persistence without Agent, Workflow,
Runtime, or combined-Persistence loading. Another process uses the public Agent
repositories without loading Team or Workflow implementations. A failure-injection test rejects the
Team response after writes and verifies rollback across Agent, Team, and content.
Dependency analysis must not introduce a new nontrivial file cycle.

See [the staged implementation plan](../architecture/persistence-refactoring-plan.md).
