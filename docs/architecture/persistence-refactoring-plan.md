# Persistence responsibility refactoring plan

This plan tracks staged implementation. Accepted architecture for the current
ownership change is [033-domain-persistence-ownership](../decisions/033-domain-persistence-ownership.md).
Future stages below are planning work, not a new Backend SPI contract.

## Target

Domain persistence depends on its record definitions and common persistence
contracts. Concrete InMemory and SQL backends implement those common contracts.
Common framework code does not choose a backend or import concrete domain code.
Composition explicitly selects implementations. Several responsibility groups
may share a diagram band; this is a dependency graph, not a tree.

## Stages

1. **Domain ownership (Refactor 09):** move schemas, repositories, and result
   queries into Agent, MultiAgent, and Workflow persistence groups. Extract shared
   record validation and explicit repository composition. Preserve the public
   Persistence API, current Storage SPI, and record/physical formats.
2. **Domain-neutral framework contract (planned):** separate the eight fixed
   repository slots and Agent-specific watermark from the common framework.
   Inventory CAS, append, indexing, admission, and multi-record preconditions
   before choosing the smallest neutral atomic operations and any domain-owned
   backend extensions. Adding a domain should not add switches to the common
   framework. Do not replace all storage with a generic key/value interface by
   assumption. Coordinate core, InMemory, SQLite, and PostgreSQL changes.
3. **Naming and placement (planned):** align the common persistence namespace,
   concrete backends, domain repositories, and composition. Resolve the existing
   `Phronomy::Persistence` public class separately from a framework namespace;
   do not silently change a public contract to make a directory diagram simpler.

The current common contract remains named `Storage`. Its eight repository slots
and admission/watermark semantics remain domain-aware until stage 2. Domain
records still share directories with execution code; inspect actual file
references before moving them into separate groups or claiming module cycles
have been eliminated.

## Invariants and gates

All repositories and ContentStore continue to join one backend transaction.
Splitting classes must not split commits. Codec response validation occurs before
the backend transaction exits. Preserve IDs, revisions, journal positions, active
constraints, record type/version/payload, and the existing F0/F1/F4/X0 guarantees.

Validate schema and backend contract tests, domain independence, cross-domain
rollback, recovery and orchestration, public API/RBS, unit/integration suites,
and the unchanged SQL examples against the candidate core. Distinguish executed
tests from unavailable live-LLM/database/CI evidence. Do not add test counts that
overlap.

For each stage, deliver complete changed files against the confirmed
`refactor/architecture` HEAD. Verify the applied commit before beginning a
subsequent package. Keep the published current-source diagram tied to applied
source; proposed graphs and target placement are identified separately.
