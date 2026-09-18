# Storage Backend composition migration

This change targets the `refactor/architecture` branch after `1b481f6`, with
shared value operations already owned by `Values::Immutable`.
It replaces the Beta Backend SPI; the gem version and persisted record formats
are not changed by this branch-only refactoring package.

## Application construction

An isolated in-memory domain is now constructed with:

```ruby
require "phronomy"

persistence = Phronomy::Persistence.in_memory
Phronomy.configure { |config| config.persistence = persistence }
```

An explicitly selected raw backend is composed once:

```ruby
require "phronomy"

backend = Phronomy::Storage::Backends::InMemory.new
persistence = Phronomy::Persistence.new(backend: backend)
Phronomy.configure { |config| config.persistence = persistence }
```

Use the same `persistence` instance wherever one storage/ownership domain is
required. Constructing several facades over one physical backend does not create
independent data, and their object identities are distinct for callers that use
Persistence identity to determine a domain. `persistence.backend` exposes the
selected raw backend for backend-specific administration such as accessing its
connection pool. Ordinary domain reads and writes still use `persistence`.

## Replaced API

| Previous API | Replacement |
|---|---|
| `Persistence::InMemory.new` | `Persistence.in_memory` |
| Backend subclass of `Persistence` | Backend subclass of `Storage::Backend`, or the same raw protocol |
| `Persistence.new` with eight raw repository keyword arguments | `Persistence.new(backend: raw_backend)` |
| Backend `super` with eight repositories | The same arguments passed to `Storage::Backend#initialize` |
| `Persistence#build_transaction_view` | A raw `Storage::Repositories` view yielded by the backend |
| `Persistence::DurableRecord` | `Storage::DurableRecord` |
| `Persistence::ConflictError` / `NotFoundError` / `SerializationError` / `UnsupportedBackendError` | The same names under `Storage` |
| `Persistence::REQUIRED_CAPABILITIES` | `Storage::Backend::REQUIRED_CAPABILITIES` |

The previous constants/helper/constructor are removed. Rescue the new storage
error constants. The public `Phronomy::AgentBusyError` admission exception remains.
This is a source/API migration, not a persisted payload migration.

## SQL implementation changes

A raw SQL backend implements `capabilities`, `transaction`, and
`assert_agent_watermark!`, and supplies all eight raw repositories to the common
Backend constructor. It exchanges `Storage::DurableRecord` and explicit ID,
revision, position, and admission metadata. It does not decode domain types.

In its transaction implementation:

1. Check out a connection and open the database transaction as before.
2. Bind contents, agents, journals, executions, workflow_states, handoff_states,
   teams, team_executions, and the watermark object to that same connection.
3. Construct `Storage::Repositories` with those eight keyword arguments and
   `watermark:`; yield this raw view inside the database transaction block.
4. Return the block result; propagate failures through the existing transaction
   rollback path. Keep the existing handling of indeterminate commit outcomes.

`Persistence#transaction` constructs the corresponding domain facades inside
that block. SQL code no longer calls `build_transaction_view` or private
`PersistenceComposition::Repositories` or domain repository wrappers. Application/bootstrap code creates the raw SQL backend,
then passes it to `Persistence.new(backend:)`.

The SQLite and PostgreSQL implementations in `phronomy-examples` at `231d253`
use the previous SPI and require this migration. Do not use their unchanged
sources with the new core. Keep this branch's API change separate from a release
until the applications/backends to be shipped with it have also migrated.

## Validation

Use the existing explicitly loaded shared contract suite with a composed
`persistence` value. All eight repositories must still commit or roll back
together. Validate root and transaction repository binding, CAS/admission and
watermark checks, record round trips, and codec failure rollback. Perform actual
SQL tests with the backend's supported database and driver versions; an
in-memory success does not prove SQL transaction/concurrency behavior.
