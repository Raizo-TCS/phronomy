# Persistence and neutral Storage SPI 2

[ADR-058](decisions/058-neutral-storage-primitives.md) defines the current
extension contract. This is an intentional breaking replacement of the old
fixed-repository Backend SPI. Application code keeps `Persistence.new(backend:)`,
`Persistence.in_memory`, its eight domain repositories and result queries.

## Ownership and composition

Storage owns `Resource`, `Backend`, `View`, `Records`, `Streams`, `Blobs`, immutable
`Entry` values, guards, conditions and neutral exceptions. It has no Agent/Team
record types, active-execution policy, content digest algorithm or watermark API.

Agent, Team, Workflow and ContentStore declare their own resource schemas.
`PersistenceComposition::StorageSchema` gathers those declarations and
`PersistenceComposition::Repositories` assembles domain wrappers over a View.
The Team and Workflow schema files live beside their features in nested loader
roots; loading metadata does not load their runtime implementations.
`ContentStore::StoredContents` owns SHA-256 identity and digest verification.
The Agent-owned `Watermark` composes guarded revision and stream-head conditions.

InMemory receives `resources:` and supplies one Monitor/snapshot transaction
across the catalog. SQL reference composition supplies the same catalog and a
separate physical table/column mapping to the neutral driver in examples
`shared/storage`. Table names, columns, indexes, DurableRecord envelopes, payloads,
format versions and content identities remain unchanged.

The [S3 closure review](architecture/refactoring-closure.md) records why these
names and placements remain and separates applied evidence from the candidate.

## Backend and View

```ruby
backend = Phronomy::Storage::Backends::InMemory.new(resources: resources)
backend.view.records(resource)
backend.view.streams(resource)
backend.view.blobs(resource)
backend.transaction { |view| ... }
view.check!(guards: guards, conditions: conditions)
```

The backend declares `spi_version: 2` and true values for `atomic_resources`,
`record_cas`, `stream_cas`, `conditional_unique`, `guarded_checks` and
`nested_savepoints`. Persistence validates these capabilities and the required
resource declarations before exposing repositories. Old duck-typed backends are
rejected with `UnsupportedBackendError`; there is no eight-slot compatibility
adapter. Public Persistence capabilities retain `atomic_all`, `atomic_admission`
and `optimistic_revision`, derived by composition from these primitives.

A root handle routes to the current transaction on the same backend/thread.
A bound view and all its handles expire on commit or rollback and reject use from
another thread. Explicit nested transactions use savepoints on the same SQL
connection, or nested InMemory snapshots. Inner success depends on outer commit;
an inner exception is re-raised after rollback and can be caught by the outer
scope. `ActiveRecord::Rollback` also propagates.

A failure during physical work marks the scope failed. Catching it inside that
same scope does not permit further operations or successful commit. Establish an
explicit inner transaction before a recoverable operation and catch outside it.
Input validation occurs before physical work. A successful optional read returning
nil is not a failed physical operation; domain required-load errors may be raised
after that read. Domain decode/returned-metadata failures stay inside the atomic
boundary so a corrupt response after a write causes rollback.

Transaction blocks must finish normally. `return`, `break` and `throw` escaping
them cause rollback and `TransactionError`. These exits are not commit controls.
Commit/rollback transport failures remain database failures; this contract does
not promise exactly-once external effects or infer commit certainty.

## Resource declarations

A `Resource` is an immutable value with `id`, `kind`, `attributes`,
`immutable_attributes`, `indexes`, `unique` and optional `guard`. Attributes use
`:string`, `:integer`, `:boolean` and their explicit `:nullable_*` forms. Keys and
text attributes use valid UTF-8 without NUL; keys are nonempty. Binary data belongs
to Blobs. No Proc, SQL expression or payload predicate is accepted.

Named equality indexes specify exact fields. Records may declare conditional
unique constraints with a symbol name, fields and equality `where` values. Null
unique-key fields are distinct, matching the default SQL unique-index semantics.
Streams have no indexed attributes; Blobs have attributes but no indexes/guards.
A record guard uses its key or an immutable non-null string attribute. A stream
guard uses its stream ID. Its anchor must be a registered Records resource.
Required anchors must exist; missing parents raise `NotFoundError` in all drivers.

## Records

| Operation | Contract |
|---|---|
| `insert(key:, revision:, attributes:, record:)` | Insert only when absent; return an independent immutable `Entry::Record`. Primary duplicates and named unique failures differ. |
| `read(key)` / `fetch(key)` | Optional nil / required `NotFoundError`. |
| `replace(key:, expected_revision:, next_revision:, attributes:, record:, expected_attributes: {})` | Check existence, revision, expected attributes, immutable fields and uniqueness atomically; next revision must equal expected + 1. Replace all attributes. |
| `delete(key:, expected_revision: Records::UNCHECKED)` | Unchecked deletion is idempotent. A supplied revision requires existence and equality. Return nil. |
| `scan(index:, equals:, after: nil, limit: nil)` | Exact named-index fields, UTF-8 byte order, exclusive key cursor, positive limit or nil for all. |
| `delete_matching(index:, equals:)` | Delete equality matches atomically; a parent-guarded resource must constrain the guard attribute. Return nil. |

An Entry carries key, revision, attributes and an opaque `DurableRecord`.
The driver does not reconstruct metadata from payload. Domain wrappers verify
that returned identity, revision and attributes agree with decoded domain data.
Workflow/Handoff choose initial revision 1 and route nil expected revision to
insert; nil is never an unchecked update. Team terminal-to-active rejection is a
domain `expected_attributes: {active: true}` precondition when saving active state.

## Streams and Blobs

Streams expose `append(stream:, expected_head:, entries:)`,
`read(stream:, after: 0, limit: nil)`, `head(stream:)`, and `delete(stream:)`.
Append takes `Entry::Append(id:, record:)`, validates the entire batch before any
write, enforces unique entry IDs within a stream, assigns contiguous positions
and updates the head atomically. Empty append still checks the expected head.
Reads return immutable `Entry::Stream(position:, id:, record:)` values in position
order. Delete removes head and entries together. The domain Journal wrapper
preserves its existing `limit: 0` empty-result behavior without a raw zero-limit
operation.

Blobs expose `put_if_absent(key:, bytes:, attributes:)`, `fetch(key)` and
`exist?(key)`. Same bytes retain the first attributes; different bytes for an
existing key raise `BlobConflictError`. Entry bytes are independent immutable
binary strings. Blob keys are arbitrary storage keys; ContentStore adds the
`sha256:<digest>` contract and maps integrity failures to its own `IntegrityError`.

## Guards, conditions and errors

`GuardRef(resource:, key:)` names a stable existing parent record. `View#check!`
acquires guards in resource/key byte order before evaluating the closed condition
set: `RevisionIs`, `StreamHeadIs`, `NoRows`. A condition must include the guard
required by its resource and scope. PostgreSQL locks parents before child heads
or records; SQLite relies on the transaction/CAS/unique constraints and must not
claim a SELECT alone reserves a writer. Transactions spanning multiple owners
must establish a consistent owner lock order; database deadlocks remain database
errors, never optimistic conflicts.

`UniqueConstraintError < ConflictError` carries the resource ID and constraint
name. Agent/Team translate only their exact `one_active_owner` constraint to
`AgentBusyError`. Their idle checks translate their own `NoRows` condition failure.
`ConditionFailedError` carries the failed condition. Duplicate identities,
stale revisions and ordinary constraint conflicts remain `ConflictError`.
`NotFoundError`, `SerializationError`, `UnsupportedBackendError` retain their
meanings; `TransactionError` identifies invalid scope use. The removed
`ActiveExecutionConflictError` and `Storage::Repositories` have no aliases.

The following sections describe the retained **domain Persistence** surface.

## Contents repository

`ContentStore::StoredContents < ContentStore::Base` supplies this domain surface
over neutral Blobs, with text/JSON helpers and canonical content-ID calculation.

Required primitive surface:

```ruby
def put(bytes, canonicalization_version:)
def fetch(content_id)
def exist?(content_id)
```

Required semantics:

- content is immutable and content-addressed;
- writing identical bytes is idempotent and returns the same content ID;
- `fetch` returns a binary `String` isolated from caller mutation;
- a missing content ID raises `Storage::NotFoundError`;
- one content ID must never resolve to different bytes; a digest-integrity
  violation raises `ContentStore::IntegrityError`.

Do not redefine the `sha256:<digest>` identity scheme in a backend. Content
references are durable data used by other Phronomy records.

## Agents repository

Required surface:

```ruby
def create(root)
def load(agent_id)
def save(agent_id, expected_revision:, root:)
def delete(agent_id)
```

`create`:

- rejects an empty Agent ID;
- rejects a duplicate Agent ID with `ConflictError`;
- returns the stored `AgentRoot`.

`load`:

- returns `Phronomy::Agent::AgentRoot`, not a raw database Hash;
- raises `NotFoundError` when missing.

These repository operations are durable-storage primitives. The higher-level
`Agent::Base.load` API first consults Runtime's process-local live ownership
registry and does not call the repository when the requested Agent is already
live.

`save` atomically checks:

```text
stored.agent_revision == expected_revision
root.agent_id == requested agent_id
root.agent_revision == expected_revision + 1
```

Any failed precondition raises `ConflictError`.

`delete` is idempotent.

## Journals repository

Required surface:

```ruby
def append(agent_id, expected_position:, records:)
def read(agent_id, after: nil, limit: nil)
def head(agent_id)
def delete(agent_id)
```

`append` atomically checks:

```text
current Journal position == expected_position
every record.agent_id == agent_id
record_id is not already present in that Agent Journal
record_id is not duplicated inside the incoming batch
```

Successful append assigns monotonically increasing sequences beginning at
`expected_position + 1` and returns the sequence-bearing `JournalRecord` values.

`read` returns records in ascending sequence order. `after: N` means records with
`sequence > N`; `limit:` caps the returned count. Caller mutation of a returned
collection must not mutate durable state.

`head` returns the current Journal position, or `0` for an empty Journal.

## Executions repository

Required surface:

```ruby
def create_active(execution)
def load(execution_id)
def save(execution_id, expected_revision:, execution:)
def list_active(agent_id)
def list(agent_id, after: nil, limit: 100)
def delete(execution_id)
def delete_for_agent(agent_id)
def assert_idle!(agent_id)
```

`create_active` performs atomic **durable** Agent execution admission. A duplicate
`execution_id` raises `ConflictError`; an already busy Agent raises
`AgentBusyError`. Runtime/EventLoop has already acquired the process-local
logical execution slot on the normal Phronomy path before this repository method
runs.

`load` returns `Phronomy::Agent::AgentExecution`, not a raw database Hash, and
raises `NotFoundError` when missing.

`save` atomically checks:

```text
stored.execution_revision == expected_revision
execution.execution_id == requested execution_id
execution.execution_revision == expected_revision + 1
```

A failed precondition raises `ConflictError`.

`list_active(agent_id)` returns the Agent's active/suspended executions.

`assert_idle!` is used inside transactions before Agent context/Knowledge changes
and destructive operations. It must raise `AgentBusyError` if an active/suspended
execution exists. A SQL implementation must make this check part of a consistency
boundary that cannot race with durable Agent execution admission; a best-effort
SELECT outside the transaction is not sufficient. Process-local Runtime
admission is an additional upstream coordination layer, not a replacement for
this durable check.

## Workflow states repository

Required surface:

```ruby
def load(workflow_instance_id)
def save(workflow_instance_id, expected_revision:, snapshot:)
def delete(workflow_instance_id, expected_revision:)
```

`load` returns `nil` when no row exists. Otherwise it returns a Hash containing a
snapshot and revision. String or Symbol Hash keys are accepted by Phronomy:

```ruby
{
  snapshot: {
    fields: { ... },
    phase: "awaiting_approval"
  },
  revision: 3
}
```

`save` is compare-and-swap:

- missing row + `expected_revision: nil` creates revision `1`;
- existing revision `N` + `expected_revision: N` creates revision `N + 1`;
- any mismatch raises `ConflictError`.

`delete` succeeds only at the supplied current revision; a mismatch raises
`ConflictError`.

Caller mutation of a loaded snapshot must not mutate durable storage.

### Workflow Runtime admission and terminal-save outcome

Same-process Workflow admission is owned by Runtime/EventLoop, not by this
repository. EventLoop acquires an opaque owner token for `workflow_instance_id`
before mutable durable load/hydration, then binds a separately generated
`fsm_session_id` only after the concrete FSMSession is constructed.

A durable Workflow terminal/halt snapshot is saved through OffloadPool while the
owning FSMSession remains nonterminal. The backend still implements only the
synchronous `save` contract above; it does not post Runtime events or decide FSM
state.

Phronomy interprets terminal-save results by semantic certainty:

```text
known successful save
  -> durable barrier may be crossed

portable known failure / known not committed
  -> barrier remains closed; Workflow error path

arbitrary storage/transport failure whose commit outcome is not established
  -> outcome unknown; barrier remains closed and Runtime fails closed
```

This distinction is independent of physical topology. A local backend can have
an uncertain outcome, and a remote backend can return a definite optimistic
conflict. Backends must therefore preserve meaningful portable errors when the
contract establishes them, and must surface other storage/transport failures
honestly rather than converting them into `ConflictError`.

### Workflow value serialization

The Workflow domain codec accepts canonical JSON-compatible snapshot values in
all drivers, including InMemory. Proc, IO, sockets and runtime callbacks are not
durable snapshot values.

A JSON/JSONB backend should document its supported value domain. A recommended
domain is:

```text
nil
String
Integer / Float representable by the chosen JSON format
true / false
Array of supported values
Hash with String/Symbol keys and supported values
```

If a value cannot be represented, raise `Storage::SerializationError` rather
than silently converting it into a lossy form. JSON backends may return String
keys after decoding; `WorkflowRunner` deliberately accepts String and Symbol keys
and normalizes them when comparing durable snapshots.

Do not add generic Ruby object serialization to Phronomy core merely to make a
particular database backend accept arbitrary Workflow values.

## Durable Agent watermark

`assert_agent_watermark!` is a domain Persistence operation. Agent-owned
`Watermark` composes a parent guard, root revision and Journal head conditions.

Phronomy uses it at durable barriers because a hydrated live Agent owns the
current logical state and Phronomy deliberately does not reload mutable Agent
state before every LLM/Tool cycle.

The backend must verify, in one storage consistency view:

```text
stored AgentRoot.agent_revision == agent_revision
current Journal position         == journal_position
```

If the Agent is missing, raise `NotFoundError`. If either watermark component
differs, raise `ConflictError`. On success return `true`.

The operation must not return a replacement AgentRoot or Journal. A mismatch is a
conflict, not a request to reload/merge mutable state.

When used inside `Persistence#transaction`, a SQL backend should perform the
watermark check in the same database transaction as the subsequent durable
write.

## Transaction contract

A transaction block may combine operations across all repositories:

```ruby
persistence.transaction do |tx|
  tx.assert_agent_watermark!(...)
  content_ref = tx.contents.put_text("...")
  tx.journals.append(...)
  tx.executions.save(...)
  tx.agents.save(...)
end
```

If an exception escapes the block, mutations performed through the transaction
view must be rolled back as one unit.

A backend must not satisfy the SPI by committing Agent, Journal, Execution, or
Workflow changes in independent transactions and relying on later compensation.

## Durable domain codecs

Repositories return Phronomy domain objects. A database backend should not copy
constructor knowledge for those objects into adapter code.

The supported canonical Hash codecs are:

```ruby
Phronomy::Agent::AgentRoot#to_h
Phronomy::Agent::AgentRoot.from_h(hash)

Phronomy::Agent::JournalRecord#to_h
Phronomy::Agent::JournalRecord.from_h(hash)

Phronomy::Agent::LLMCallRecord#to_h
Phronomy::Agent::LLMCallRecord.from_h(hash)

Phronomy::Agent::AgentExecution#to_h
Phronomy::Agent::AgentExecution.from_h(hash)
```

`AgentExecution.from_h` recursively restores nested `working_records` as
`JournalRecord` objects and nested `llm_calls` as `LLMCallRecord` objects.
String and Symbol top-level keys are accepted by these new execution/call codecs,
which permits adapters to use parsed JSON without reimplementing constructors.

The current canonical `JournalRecord` Hash does not contain `correlation_id`.
Legacy durable Journal Hashes that still contain that key may be passed to
`JournalRecord.from_h`; the legacy key is accepted and ignored. Backends must not
synthesize or populate `correlation_id` for new canonical Journal records, and
they are not required to eagerly rewrite existing durable rows solely to remove
the old physical value.

This is a targeted migration rule for the removed generic identity field. It does
not establish a general unknown-field or long-term codec/schema-versioning
policy.

Domain codecs own canonical Hash representation. The raw driver stores the
DurableRecord envelope and separately supplied metadata without interpreting
domain payload fields.

## Conformance tests

Phronomy ships its backend-independent RSpec shared examples as explicit test
support in the released gem. Backend projects opt in with:

```ruby
require "phronomy/testing/persistence_contract"
```

RSpec remains a **development/test dependency of the backend project**, not a
Phronomy runtime dependency. Ordinary `require "phronomy"` does not load RSpec,
and Phronomy's production Zeitwerk eager-load explicitly excludes the contract
support paths.

The entry point registers these shared examples:

```text
a persistence content store
an Agent repository
a Journal repository
an Execution repository
a workflow state repository
a Handoff state repository
a Team repository
a Team execution repository
neutral storage primitives
storage transaction boundaries
a Persistence backend
```

A backend's RSpec suite can apply the complete contract as follows:

```ruby
require "phronomy"
require "phronomy/testing/persistence_contract"

RSpec.describe MyPersistenceBackend do
  let(:persistence) { Phronomy::Persistence.new(backend: described_class.new(...)) }

  it_behaves_like "a persistence content store"
  it_behaves_like "an Agent repository"
  it_behaves_like "a Journal repository"
  it_behaves_like "an Execution repository"
  it_behaves_like "a workflow state repository"
  it_behaves_like "a Handoff state repository"
  it_behaves_like "a Team repository"
  it_behaves_like "a Team execution repository"
  it_behaves_like "a Persistence backend"
end
```

`Persistence.in_memory` is run through the same shipped contract source in
Phronomy CI. The files under `spec/support/shared_examples/` are compatibility
require wrappers only; the authoritative shared-example implementations live
under `lib/phronomy/testing/persistence_contract/` so the core suite and external
backends cannot drift through copied definitions.

The generic suite verifies repository behavior, CAS semantics, durable execution
admission, mutation isolation, and whole-backend transaction behavior. Runtime
same-process ownership/admission is tested separately because it is not a
Persistence Backend SPI responsibility. Database-specific concurrency/locking
mechanisms remain backend integration-test concerns; the SPI specifies outcomes
rather than a particular SQL locking strategy.

## SQL implementation guidance

The SPI specifies outcomes, not a locking mechanism. Typical SQL implementations
may use combinations of:

- unique constraints;
- conditional `UPDATE ... WHERE revision = ?`;
- row locks;
- serializable/repeatable-read isolation where appropriate;
- partial unique indexes for durable active Agent execution admission;
- transaction-scoped checks for Agent revision + Journal head.

Backend-specific database exceptions should be translated to the Phronomy error
contract where their meaning is known.

## Coordination domain repositories

Handoff starts at revision 1 with expected revision nil; later saves advance one
revision. Team roots and executions begin at revision 0. Team admission retains
`AgentBusyError`; stale CAS and duplicate identities use `ConflictError`.
Missing Team/execution loads raise `NotFoundError`; absent Handoff state returns
nil. The unchanged record types are `phronomy.handoff_state`, `phronomy.team_root`
and `phronomy.team_execution`, all version `0.1`.

Backend authors should also read the [SPI 2 migration guide](migrations/neutral-storage-spi.md).
The Stable/Beta product API snapshot and the explicit Storage SPI 2 signature
snapshot are separate gates. Live PostgreSQL locking and failure tests must run
against the candidate core and examples revisions; earlier SPI results do not
satisfy this gate.
