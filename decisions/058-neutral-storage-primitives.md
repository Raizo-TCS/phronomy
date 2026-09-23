# ADR-058: Neutral Storage primitives and scoped transactions

## Status

Accepted. Applied and verified in Refactor 35 (Storage S2b/S2c), core
`ebd99623f94c8b2db2d74355bfa39f01550778a0` and examples
`68a0bbd0e354b9e00bbfed728ad2b769b389ed8a`.

## Context

S1 inventoried 37 raw methods across eight required domain slots. Moving their
classes did not remove Agent watermark or active-owner policy from shared
storage. S2a fixed concrete transaction and update differences first. S2b now
changes the extension contract while preserving domain APIs and durable data.

## Decision

1. Replace the eight-slot Backend/Repositories SPI with declared Resources and
   Records, Streams, Blobs accessed through View. Storage has no domain codecs,
   active-execution interpretation, content digest or Agent watermark method.
2. Keep schemas, encoding, initial revisions, active-state interpretation and
   metadata validation in their features. Composition gathers declarations and
   builds domain wrappers. Team/Workflow schema loader roots do not load runtime.
3. Use named equality indexes, conditional unique constraints, immutable metadata,
   revision CAS, stream head CAS and a closed guarded-condition set. Parent guards
   precede child locks. Required parent absence is uniformly NotFoundError.
4. Keep one transaction domain, scoped views, same-connection savepoints and root
   handle routing. Reject expired/cross-thread views and failed physical scopes.
   Reject non-local block exits with TransactionError and rollback. A successful
   optional read returning nil is not a failed physical operation.
5. Report neutral UniqueConstraintError(resource ID, constraint name) and
   ConditionFailedError(condition). Only owning domain repositories map exact
   active constraints to AgentBusyError. Remove the old domain-named error alias.
6. Share neutral SQL operations in examples/shared/storage, with explicit dialect
   differences and separate domain/table composition. Keep all existing tables,
   indexes, envelope formats, payloads, IDs and content bytes. Nullable unique-key
   fields are distinct, matching SQL default uniqueness semantics.

## Supersession scope

This amends ADR-032's raw eight-slot contract, ADR-033's remaining fixed raw
boundary, ADR-043's domain-named raw exception and ADR-057's old-SPI-only limit.
Their domain ownership, composition, savepoint and uncertainty decisions remain.
No historical artifact is silently reinterpreted as a current SPI specification.

## Public contract and migration

Persistence's constructor, in_memory, eight accessors, result queries and public
capabilities remain. Backend SPI 2 is intentionally breaking; legacy duck-typed
backends fail capability validation. There is no compatibility facade or alias.
See the [contract](../persistence-backends.md), [migration guide](../migrations/neutral-storage-spi.md),
RBS and explicit SPI 2 snapshot. Ordinary product API snapshots remain separate.

## Validation and remaining gates

Shared conformance tests cover opaque data, CAS, named constraints, parents,
Unicode cursor ordering, streams, binary blobs, all-resource rollback, nested
savepoints, view lifetime, thread confinement and non-local exits. Domain tests
retain F0/F1/F4 behavior and X0 limitations. SQLite old/new/old round-trip checks
cover all eight resources and unchanged schema. The applied SPI 2 pair passed
[PostgreSQL 17.11 CI](https://github.com/Raizo-TCS/phronomy-examples/actions/runs/35827495677)
on Ruby 3.2/3.3/3.4, with 119 examples per version and fresh-pool reload. Both
checkout SHAs were verified. Earlier SPI CI was not used as substitute evidence.
No stronger commit certainty, distributed Workflow admission or external-effect
retry is introduced.

## S3 internal responsibility clarification

Refactor 36 keeps all public SPI 2 signatures and Resource identity rules.
Resource normalizes a schema object or resource ID before GuardRef/Condition
construction; the cooperation method is `@api private`, not a new backend
extension point. Generic Validation handles scalar validation and copying and
must not depend on Resource. View still enforces catalog membership and exact
schema identity. This removes the internal Resource/Validation cycle without
changing a public name, transaction, stored record or physical backend.

See the [closure review](../architecture/refactoring-closure.md) for retained
placements and the separate distribution application gate.
