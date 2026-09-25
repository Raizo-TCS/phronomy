# Storage asynchronous execution and ContentStore ownership

P4 adds the public Beta `Phronomy::Storage::AsyncClient`. Synchronous storage
backends and `Persistence#transaction` keep their existing interfaces. Backend
authors implement no scheduler or async methods.

## Public transaction API

Construct `Storage::AsyncClient.new(backend: raw_backend, pool: nil)` around a
Storage SPI 2 backend. For an existing Persistence facade, use
`persistence.backend`. The transaction block receives a **raw Storage::View**,
not the domain repositories yielded by `Persistence#transaction`.

`transaction_async(cancellation_token: nil, timeout: nil) { |view| ... }`
returns the pool's original TaskResult. The complete transaction runs on one
worker, using the backend's normal connection and scope. Do not split a
transaction across workers or wait for another TaskResult inside its block.
Explicit synchronous `backend.transaction` calls within the block retain nested
savepoint behavior.

### Complete offline example

This requires a checkout containing P4; the previously released 0.27.0 gem does
not contain the new client. It uses only the public raw storage contract.

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

Internal `Storage::AsyncClient.submit(pool:)` accepts an existing synchronous
storage unit. This is private framework API, not an application extension API.
It submits exactly once and adds no transaction, token, or timeout. This lets
domain operations preserve their own transaction and reconciliation boundaries.
See the [operation inventory](../architecture/storage-execution-boundaries.md).

In particular, a Workflow runner may have only an injected repository rather
than access to its raw backend. Internal submit therefore accepts a callable
and the owner's pool; it does not require a dummy backend or a Persistence
facade. Public transaction_async requires a real SPI 2 backend.

Durable commit/readback policy, admission release, callback delivery and the
application of results to live state remain with Agent/Workflow/MultiAgent.
No cancellation condition is added to existing terminal saves. Tool execution,
authorization, tracing and application approval listeners retain their own
execution boundaries.

## ContentStore path and diagram

`ContentStore::StoredContents` moves from `content_store/stored_contents.rb` to
`content_store/backends/stored_contents.rb`. Its body, constant, synchronous
operations and digest rules are unchanged. Zeitwerk collapses this new directory
and `storage/async/`. Existing `Storage::Backends` remains a namespace.
Use normal `require "phronomy"`; no shim reintroduces an implementation dependency
into the ContentStore contract. ContentStore receives no artificial async API.

The measured diagram now places M10 ContentStore with Contracts in B5 and adds
M69 Storage AsyncClient and M73 StoredContents implementation in B4. Text panels
are transparent. Arrows targeting M33/M41/M44 are hidden by display settings;
all measured dependencies, source evidence and matrix cells remain available.
