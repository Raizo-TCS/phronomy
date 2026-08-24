# Persistence backend contract

`Phronomy::Persistence` is the single durable-state backend abstraction used by
stateful Agents and durable Workflows. This document is the normative contract
for authors of custom Persistence backends.

The Backend SPI is **Beta**. It may evolve in a minor pre-1.0 release, but a
backend should not depend on Phronomy private APIs or Runtime internals.

## Architecture boundary

A backend implements durable storage only:

```text
Application
    ↓
Agent / Workflow
    ↓
Runtime / EventLoop / ExecutionCoordinator
    ↓
Phronomy::Persistence synchronous Backend SPI
    ↓
Database / durable storage
```

Persistence does not own live Agent identity, top-level Runtime admission, or
live execution state. In particular, a backend must not persist or reconstruct
the following as part of this SPI:

- Runtime Agent ownership-registry entries;
- EventLoop Agent top-level admission entries;
- EventLoop Agent execution-directory entries;
- `AgentInvocation`;
- `FSMSession`;
- `Task` or callbacks;
- EventLoop queue contents;
- Runtime Workflow admission entries;
- in-flight provider operations.

Persistence operations are synchronous. Framework-owned blocking Persistence I/O
is submitted to the Runtime OffloadPool by Phronomy; a backend must not post
EventLoop events or introduce `load_async` / `save_async` variants into this
contract.

## Required root surface

A Persistence backend exposes five durable repositories:

```text
contents
agents
journals
executions
workflow_states
```

and two root operations:

```ruby
persistence.transaction { |tx| ... }
persistence.assert_agent_watermark!(
  agent_id:,
  agent_revision:,
  journal_position:
)
```

The object yielded by `transaction` is a transaction-scoped Persistence view. It
must respond to all five repository accessors and
`assert_agent_watermark!`. It may be the Persistence instance itself, but SQL
backends may instead yield an object bound to a checked-out connection or
transaction session.

## Required capabilities

Every backend must advertise:

```ruby
{
  atomic_all: true,
  atomic_admission: true,
  optimistic_revision: true
}
```

`Phronomy::Persistence::REQUIRED_CAPABILITIES` is the executable definition of
this requirement.

### `atomic_all`

All durable repositories must be able to participate in one atomic transaction
domain. A transaction may change `contents`, `agents`, `journals`, `executions`,
and `workflow_states` and then either commit all changes or roll them all back.

This requirement deliberately does not claim exactly-once semantics after an
indeterminate database/network failure. If the underlying database cannot tell
the caller whether a commit happened, the backend should surface the storage
failure rather than pretending the outcome is known.

### `atomic_admission`

This capability is a **durable Agent execution integrity defense**. It is not the
primary same-process Agent ownership/admission mechanism and it is not Workflow
distributed locking.

For one Agent, `executions.create_active` must atomically guarantee both:

```text
execution_id is unique
AND
no active/suspended execution already exists for agent_id
```

A conflict with an existing active/suspended execution raises
`Phronomy::AgentBusyError`.

Within one process, Runtime/EventLoop admission is acquired before the initial
Persistence operation and is the primary competing-execution exclusion
mechanism. `atomic_admission` remains required as the durable second line of
defense against stale paths, durable conflicts, and unsupported cross-process
races. It must not be removed merely because Runtime admission exists.

Workflow admission remains Runtime/process-local. Cross-process Agent or
Workflow ownership/lease/fencing is a separate distributed-coordination concern
and is not part of this Backend SPI.

### `optimistic_revision`

The backend must implement compare-and-swap semantics used by Agent roots,
Agent executions, Journals, Workflow snapshots, and the durable Agent watermark.
Stale writers must receive `Phronomy::Persistence::ConflictError`; they must not
silently overwrite newer durable state.

## Error contract

Backends should translate backend-specific constraint errors into the following
portable Phronomy errors when the meaning matches.

### `Phronomy::Persistence::NotFoundError`

A requested durable record does not exist.

### `Phronomy::Persistence::ConflictError`

A persistence precondition failed, including revision, Journal position,
identity, duplicate-ID, or compare-and-swap conflicts.

### `Phronomy::AgentBusyError`

A durable nonterminal Agent execution already exists and another durable
execution record cannot be established. Phronomy also uses the same public error
for a competing process-local top-level request rejected by Runtime/EventLoop
before the backend is called.

### `Phronomy::Persistence::SerializationError`

The backend cannot encode a value into its supported durable representation.
This is intended primarily for durable backends whose Workflow state domain is
narrower than the InMemory backend's Ruby-object domain.

### `Phronomy::Persistence::UnsupportedBackendError`

The backend does not provide a required structural or capability contract.

Database availability, connection loss, and other transport/storage failures
must not be misreported as ordinary optimistic conflicts merely to fit this
error taxonomy.

## Contents repository

The content repository should normally inherit from
`Phronomy::ContentStore::Base`, which supplies text/JSON helpers and the canonical
content-ID calculation.

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
- a missing content ID raises `Persistence::NotFoundError`;
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

### Workflow value serialization

`WorkflowContext#to_h` may contain ordinary Ruby application values. The
InMemory backend can preserve a broader set of Ruby values than a JSON database.
A durable backend is not required to serialize arbitrary Ruby objects such as
`Proc`, IO objects, sockets, or runtime callbacks.

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

If a value cannot be represented, raise `Persistence::SerializationError` rather
than silently converting it into a lossy form. JSON backends may return String
keys after decoding; `WorkflowRunner` deliberately accepts String and Symbol keys
and normalizes them when comparing durable snapshots.

Do not add generic Ruby object serialization to Phronomy core merely to make a
particular database backend accept arbitrary Workflow values.

## Durable Agent watermark

`assert_agent_watermark!` is a public **Backend SPI** operation. It is not an
ordinary application API.

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

The canonical Hash representation is the Phronomy/domain boundary. A backend is
free to map that representation to normalized SQL columns, JSON, or another
storage format internally.

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
a Persistence backend
```

A backend's RSpec suite can apply the complete contract as follows:

```ruby
require "phronomy"
require "phronomy/testing/persistence_contract"

RSpec.describe MyPersistenceBackend do
  let(:persistence) { described_class.new(...) }

  it_behaves_like "a persistence content store"
  it_behaves_like "an Agent repository"
  it_behaves_like "a Journal repository"
  it_behaves_like "an Execution repository"
  it_behaves_like "a workflow state repository"
  it_behaves_like "a Persistence backend"
end
```

`Persistence::InMemory` is run through the same shipped contract source in
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
