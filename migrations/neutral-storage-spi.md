# Migrating to neutral Storage SPI 2 (Refactor 35)

Apply matching core and examples changes together. Existing SQL databases need
no schema or payload migration. Applications continue using Persistence domain
repositories. Direct Backend implementations and callers must migrate.

| Previous extension point | SPI 2 |
|---|---|
| Eight repository keywords to Backend | `resources: [Resource, ...]` |
| `backend.agents`, `backend.executions`, etc. | `backend.view.records(resource)`; domain names stay on Persistence |
| Journal raw repository | `view.streams(resource)` with `Entry::Append` inputs |
| Raw ContentStore repository | `view.blobs(resource)`; `ContentStore::StoredContents` owns digest behavior |
| `Storage::Repositories` transaction view | `Storage::View` bound to a transaction scope |
| `assert_agent_watermark!` on raw Backend | Agent-owned Watermark composes GuardRef, RevisionIs and StreamHeadIs |
| ActiveExecutionConflictError | UniqueConstraintError with exact resource/constraint; NoRows condition for idle |
| Three domain-named raw capabilities | spi_version 2 and six neutral capabilities |

A driver implements the protected physical operations used by Records, Streams,
Blobs and guards, plus `storage_transaction`. Reuse the common scope lifecycle;
do not override `transaction` with a view that bypasses it. Return independent
Entry values and never decode domain payload to reconstruct index metadata.
A non-subclass backend must provide the same public protocol and semantics.
The SQL reference driver receives immutable physical mappings independently of
resource declarations; no resource-ID case switch selects domain SQL behavior.

Repository wrappers obtained inside a transaction expire with that transaction.
Do not retain them in application objects. Cache root repositories/handles when
needed: they route to the current transaction on the same thread. Recover from
an operation failure only outside an explicit inner savepoint. Catching a failure
inside its failed scope prevents further work and commit. Complete transaction
blocks normally; return/break/throw raises TransactionError after rollback.

Initial Workflow/Handoff saves still use expected_revision nil and return the
existing domain result. Storage Records itself requires explicit insert versus
replace. Missing required parent records now consistently raise NotFoundError;
this closes prior InMemory/SQLite/PG differences for orphan raw writes. Nonempty
keys and text attributes must be valid UTF-8 without NUL. Nullable unique keys
are distinct. Domain Journal limit zero remains an empty result.

Run the shipped domain and neutral conformance suites, the dedicated SPI 2/RBS
checks and each physical driver's concurrency/failure tests. For PostgreSQL run
the real server gate with the matching candidate core, then verify fresh-pool
reload. Existing S2a CI is historical evidence, not validation of this SPI.
