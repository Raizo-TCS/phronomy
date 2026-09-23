# ADR-057: Storage update constraints and explicit transaction boundaries

## Status

Accepted for implementation in Refactor 34 (Storage S2a).


The raw fixed-repository/error portions are amended by [ADR-058](058-neutral-storage-primitives.md). Domain ownership and applicable transaction/uncertainty decisions remain in force.

## Context

The existing eight-repository SPI had three concrete behavioral differences.
InMemory allowed an inactive Agent execution to become active while another
execution for that Agent was active. SQL rejected that update. SQL Journal
append serialized each record immediately before inserting it; catching an
invalid later record inside the outer transaction could commit earlier rows
without advancing the head. Explicit nested InMemory transactions restored an
inner snapshot, whereas ActiveRecord's default nesting joined the outer scope.

## Decision

Keep the existing SPI and data formats while closing these differences.

1. InMemory checks active-owner uniqueness on Agent execution updates under the
   same Monitor as revision validation and writes. Exclude the updated identity.
   Report `Storage::ActiveExecutionConflictError` and leave record and revision
   unchanged on rejection. Team terminal execution reactivation remains forbidden.
2. Both SQL Journal adapters serialize the complete batch and normalize the
   expected position before any writes. Preserve ID checks, lock order, CAS,
   return values and transaction-bound connection access.
3. Explicit `Backend#transaction` / `Persistence#transaction` nesting on the same
   backend and synchronous execution context uses savepoint semantics. Roll back
   a failed inner scope and re-raise the same exception. The outer scope may catch
   it and continue. Inner success is not an independent commit: outer failure
   rolls back both. SQL uses `requires_new: true` on the same checked-out
   connection. InMemory retains its reentrant Monitor and snapshots.

The SQL wrappers also re-raise `ActiveRecord::Rollback` after ActiveRecord rolls
back and consumes it. The Storage API does not use an exception as a successful
return value. Repository operations on a bound view still join that scope; this
change does not introduce per-operation savepoints or separate connections.

## Compatibility and migration

This intentionally changes SQL behavior. If an application catches an inner
failure, writes from that failed inner block will no longer remain in the outer
transaction. Catch outside the explicit inner block and re-read any conditions
needed to continue. Catching a database failure inside the same transaction view
and continuing is not a portable recovery contract; propagate it or isolate the
operation in an explicit inner transaction before executing it.

`ActiveRecord::Rollback` now propagates from the Storage/Persistence boundary.
Callers relying on ActiveRecord's silent rollback must catch it outside that
boundary. Backend authors should run the public Persistence contract suite;
method signatures and required capability keys are unchanged.

No schema, record type/version, payload, content identity or public facade
changes are required. Unknown commit outcomes remain backend/database failures;
this decision does not add exactly-once behavior or retry external effects.

## Verification and remaining work

Shared tests cover rejected update immutability, nonconflicting active updates,
invalid later Journal records, retrying the same record IDs, inner-only rollback,
exception identity, continued outer writes, normal results and outer rollback.
Both raw Backend and domain Persistence transaction entry points are exercised.
SQL-specific tests cover `ActiveRecord::Rollback` propagation.

The new neutral Records/Streams/Blobs SPI, failed-view lifecycle and explicit
non-local block-exit handling (`return` / `break` / `throw`) belong to S2b.
Do not use non-local exits as portable commit controls. PostgreSQL live-server
conformance and concurrency tests remain a required integration gate; source
parity or tests with a non-PostgreSQL connection do not satisfy that gate.
