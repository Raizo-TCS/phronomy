# Storage asynchronous execution and ContentStore ownership

Storage execution schedules raw transactions without taking ownership of domain
persistence rules. The public Beta `Phronomy::Storage::AsyncClient` introduced
in P4 wraps a synchronous backend; domain stores retain their own operations.

For example, an application can write a raw notes resource with this client.
An Agent instead uses its domain store, whose transaction participates through
the neutral `Persistence#atomic` coordinator. Backend authors implement no
scheduler or asynchronous methods.

## Public transaction API

The client schedules one backend transaction and returns its completion handle.
The transaction block receives a raw Storage view valid only for that scope.

For example, with `stores = PersistenceComposition.in_memory`, construct the
client around `stores.coordinator.backend`. Pass `stores.agent` to Agent,
`stores.multi_agent` to MultiAgent, and `stores.workflow` to Workflow. These
domain components are distinct from the raw backend and coordinator.

Construct `Storage::AsyncClient.new(backend: raw_backend, pool: nil)` around a
Storage SPI 2 backend. The block receives a **raw Storage::View**.
`stores.coordinator.atomic` instead yields a shared participation scope;
`stores.agent.transaction` and `stores.multi_agent.transaction` yield their
domain-owned records and scope. There is no coordinator `transaction` facade.

`transaction_async(cancellation_token: nil, timeout: nil) { |view| ... }`
returns the pool's original TaskResult. The complete transaction runs on one
worker, using the backend's normal connection and scope. Do not split a
transaction across workers or wait for another TaskResult inside its block.
Explicit synchronous `backend.transaction` calls within the block retain nested
savepoint behavior.

### Complete offline example

An application owns its resource declarations and chooses its backend. This
example saves a note in a custom resource and receives its payload after commit,
using only the public raw storage contract.

```ruby runnable
require "phronomy"
require "json"

resource = Phronomy::Storage::Resource.new(id: "example.notes", kind: :records)
backend = Phronomy::Storage::Backends::InMemory.new(resources: [resource])
client = Phronomy::Storage::AsyncClient.new(backend: backend)

begin
  record = Phronomy::Storage::DurableRecord.new(
    record_type: "example.note", format_version: "0.1", payload: {"text" => "saved"}
  )
  task = client.transaction_async do |view|
    rows = view.records(resource)
    rows.insert(key: "note-1", revision: 1, attributes: {}, record: record)
    rows.fetch("note-1").record.payload
  end
  puts JSON.generate(task.wait_result)
ensure
  Phronomy.reset_runtime!
end
```

The output is `{"text":"saved"}`. Return a value from the transaction. A bound
view or resource handle becomes invalid after the block finishes, even if it
was returned through TaskResult. Scope also rejects access from another thread.
Exceptions and invalid non-local block exits roll back through the existing
backend rules; no new transaction implementation is introduced.

## Admission, cancellation and ownership

Admission and completion govern the submitted operation, while the backend owns
the physical transaction. A settled timeout or cancellation does not establish
whether a transaction that already started eventually committed.

For example, a notes write may outlive its TaskResult timeout and still commit.
The application must inspect durable state before retrying an uncertain write.

Construction starts no Runtime. Each call resolves the current default pool,
unless an explicit caller-owned `pool:` was supplied. Runtime reset does not
transfer ownership of an injected pool.

Admission uses `on_full: :raise`: a full or stopped pool raises immediately.
Queue wait counts toward `timeout`. Cancellation/timeout before worker pickup
skips the transaction. After work starts, TaskResult may settle while the
physical transaction continues and commits. A timeout or cancellation is **not
a rollback guarantee**. The client does not kill a thread, add retries, or claim
that an uncertain commit succeeded or failed. Applications needing a durable
outcome must reconcile through their domain's identities and stored state.

## Existing Agent, Workflow and coordination operations

Domain execution schedules complete persistence operations while each operation
retains its transaction and reconciliation policy. Agent, Workflow and MultiAgent
use their execution environments or `Execution.submit`, not a Storage forwarding
helper. Submission adds no transaction, token or timeout.

For example, Workflow terminal persistence saves its snapshot and reads back an
uncertain response within its own operation. A Workflow runner needs its injected
repository and execution environment; it does not need a dummy raw backend to
submit that operation. See the 14-site
[operation inventory](../architecture/storage-execution-boundaries.md).

Durable commit/readback policy, admission release, callback delivery and the
application of results to live state remain with Agent/Workflow/MultiAgent.
No cancellation condition is added to existing terminal saves. Tool execution,
authorization, tracing and application approval listeners retain their own
execution boundaries.

## ContentStore path and diagram

Content management owns canonical bytes, content identity and integrity over
neutral Storage. The service does not select a physical backend or introduce
another execution client.

For example, StoredContents writes canonical JSON through a supplied blob view;
the Persistence content adapter translates known storage failures for its domain
caller. Neither operation creates a new worker or chooses a database.

P4 originally moved `ContentStore::StoredContents` into
`content_store/backends/stored_contents.rb`. [ADR-062](../decisions/062-content-store-service.md)
supersedes that split: the implementation now lives at
`content_store/stored_contents.rb`, beside its shared API and owned schema.
The obsolete backend directory and collapse entry are deleted without a shim.
Its constant, synchronous operations, digest rules and exceptions are unchanged.
Use normal `require "phronomy"`; internal file paths are not a public load API.
Zeitwerk still collapses `storage/async/`. `Storage::Backends` remains a namespace.
ContentStore receives no artificial async API.

M10 is G57 Content Service in B3, outside Backend Contracts/Implementations;
M73 is retired. M69 Storage AsyncClient stays in B4. Text panels are transparent.
Arrows targeting M33/M41/M44 are hidden by display settings; all measured
dependencies, source evidence and matrix cells remain available.
