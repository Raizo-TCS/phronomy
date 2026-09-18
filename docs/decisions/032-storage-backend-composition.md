# 032: Compose domain persistence over a storage backend

- Status: Accepted
- Date: 2026-09-17
- Refines: [014-unified-persistence-durable-state](014-unified-persistence-durable-state.md)

## Context

The previous `Persistence` class combined raw storage contracts with domain
repository construction, codecs, and result queries. Physical backends inherited
that class, and SQL implementations called `build_transaction_view` to construct
upper domain facades. This made the common storage boundary depend on the
entities whose records it stored.

## Decision

1. `Storage::Backend` and `Storage::Repositories` define synchronous raw storage
   and transaction-view protocols. `Storage::DurableRecord` and portable storage
   errors belong to this common contract. These files do not depend on Agent,
   MultiAgent, Runtime, or the domain-facing Persistence implementation.
2. Concrete backends depend on that contract and their physical storage tools.
   The in-memory implementation lives in `storage/backends/in_memory.rb` and
   retains its single Monitor and single all-repository transaction snapshot.
3. `Persistence.new(backend:)` composes the domain service over a selected backend.
   The existing domain codecs and facades remain in `persistence/`. They validate
   and convert records using the actual domain record definitions.
4. The same facade builder wraps the root backend and the raw view yielded by
   `backend.transaction`. Transaction conversion stays inside the backend block;
   conversion failures therefore participate in its normal rollback semantics.
5. `Persistence.in_memory` is the explicit convenience assembly. Backend selection
   belongs to construction, not to the common storage contract.
6. Replace the old Persistence subclass SPI, raw-repository constructor,
   `build_transaction_view`, `Persistence::InMemory`, and old record/error owners.
   No compatibility aliases or second implementation of that SPI are retained.
   See the [migration guide](../migrations/storage-backend-composition.md).

Both concrete backends and domain persistence depend on the common storage
contract. These are sibling responsibility groups, not a requirement for one
strict vertical ordering of the entire system. Runtime calls to a selected
backend do not establish a source dependency on that backend's concrete class.

## Preserved contracts

All eight repositories remain one atomic transaction domain. Their IDs,
revision/position checks, active execution constraints, record types, format
versions, and payload schemas are unchanged. ContentStore retains its separate
canonicalization API. The shared `AgentBusyError` remains the existing admission
failure contract; its standalone definition does not load Agent implementation.

Atomic durable-state transitions remain CONDITIONAL on a conforming backend for
F0 operations; commit-outcome certainty under F1 remains NO as a general promise.
F4 restart readability remains CONDITIONAL on retained confirmed durable data;
InMemory does not provide disk retention. X0 external effects remain outside the
storage transaction. This change adds no asynchronous SPI or execution ownership.

## Consequences and validation

Custom SQL backends migrate their superclass, record/error references, and raw
transaction view construction. They keep all transaction repositories and the
watermark bound to the same connection. Applications wrap a raw backend once.

An isolated-load architecture test checks that storage can use opaque records and
admission without loading domain or execution code. Public contract tests cover
root/transaction view separation and removal of the replaced SPI. Existing
repository conformance, commit/rollback/CAS, codec, recovery, and integration tests
remain required. Codec rejection after a physical write must roll back the whole
transaction, not leave a committed partial operation.

Shared Immutable ownership has already moved to `Values::Immutable`; this change
preserves that boundary. Domain model placement and unrelated module cycles
remain separate subsequent changes. In particular, DurableCodec retains its
TeamRoot / TeamExecution references to validate and reconstruct Team records.
Those belong to domain persistence, not to the common storage contract.
Moving a type or hiding a constant reference alone is not evidence that this
storage boundary has been separated.
