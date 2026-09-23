# Persistence responsibility refactoring plan

The Storage staged implementation reaches its bounded S3 cleanup in Refactor 36;
application verification remains. The broader initial review still has open
proposals recorded in the remaining responsibility plan.
[ADR-033](../decisions/033-domain-persistence-ownership.md) established domain
ownership; [ADR-058](../decisions/058-neutral-storage-primitives.md) now defines
the neutral Storage SPI. Historical raw contracts are not the current API.
See the [remaining responsibility plan](remaining-refactoring-plan.md) for the
applied commit pair and the [closure review](refactoring-closure.md) for the
final naming, placement and evidence boundary.

## Target and current ownership

Domain repositories own record meanings, codecs, revisions and business
constraints. Storage owns typed neutral resources, Records/Streams/Blobs,
conditions and transaction scopes. Concrete InMemory and SQL drivers implement
physical operations. Composition selects implementations and assembles domain
wrappers; Storage does not import concrete domain implementations.

The public `Phronomy::Persistence` facade remains the application entry point.
It is distinct from `Phronomy::Storage`, the backend extension contract.
Directories express responsibility; existing public constants need not be
renamed to match every directory. The dependency graph is not a tree.

## Stages

| Stage | Result |
|---|---|
| 1. Domain ownership | Refactor 09 moved schemas, repositories and queries to their domains. Later layout work placed record definitions and ownership contracts beside those features. |
| 2. Neutral contract | Refactors 34 and 35 unified the failure/transaction boundaries and replaced eight raw repository slots with Resources, Records/Streams/Blobs and guarded conditions. Core, InMemory, SQLite and PostgreSQL were migrated together. Applied SPI 2 passed S2c, including real PostgreSQL. |
| 3. Naming and placement | Refactor 36 retains the facade/SPI names, feature schemas, composition and reference-driver locations. Resource owns schema-reference normalization; generic Validation does not depend on Resource. Documentation records current status and historical boundaries. Distribution application verification remains separate. |

## Invariants and gates

All repositories and ContentStore continue to join one backend transaction.
Splitting classes must not split commits. Codec response validation stays inside
the atomic boundary. IDs, revisions, journal positions, active constraints,
record type/version/payload and the F0/F1/F4/X0 limits remain unchanged.

Product API and Storage SPI snapshots, RBS, existing domain/backend conformance,
unit/integration suites, SQL examples and isolated gem loading verify the
implemented boundary. Record which tests ran against which tree: Refactor 35's
PostgreSQL CI is evidence for Refactor 35, not a claim that unpublished
Refactor 36 ran remotely. Refactor 36 does not change SQL or its public protocol.

Keep the applied-source diagram until the delivered candidate is applied and
verified. Remaining directory cycles and runtime collaboration are recorded,
not described as eliminated by moving files. Future behavior, performance or
distributed-operation work requires its own scope and evidence.
