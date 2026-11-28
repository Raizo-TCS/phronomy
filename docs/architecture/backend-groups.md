# Backend responsibilities and asynchronous execution clients

The diagram distinguishes responsibility **groups** from its display layers.
The earlier B1-B6 horizontal bands and topical columns are restored for
readability. `G14`, `G46`, `G47` and `G48` remain stable responsibility identifiers;
boundary permissions follow those responsibilities, not B/G numbers or positions.
Each source directory keeps its own module box and stable module ID. Restoring
the display does not undo the separation of backend contracts and execution.

The restored display puts separated Backend Contracts in B5, alongside but
distinct from Engine Internals and Execution Contracts. B4 holds Async Clients and separately grouped Implementations. Execution
operations and values now share G58; the former G59 service split is removed. Backend directories awaiting separation remain visibly mixed
in B4; their contracts move to B5 in their implemented phase. These are display
positions, not a shared architectural level or namespace.

| Group | Responsibility | Dependency rule |
|---|---|---|
| G14 Engine Internals | Runtime, workers, FSM and EventLoop | No feature-specific backend or client dependencies |
| G58 Execution Framework | Submission protocol, TaskResult, Execution, Blocking, controls and common rules | Only Execution and Common, including neutral settings; Engine implements the mechanism |
| G46 Async Clients | Execute synchronous backend operations through Execution | Use Backend and Execution contracts; no direct Engine or concrete backend selection |
| G47 Backend Contracts | Synchronous SPI, values, errors and shared rules | No Engine, Execution Services, Async Client or concrete implementation dependencies |
| G48 Backend Implementations | Implement the synchronous backend SPI | Depend on the corresponding Contracts; no Engine, Execution Services or client dependencies |
| G57 Content Service | Content IDs, canonical text/JSON and digest integrity over Storage | Uses neutral Storage and Common; no physical backend, Engine or domain orchestration dependencies |

Composition chooses concrete backends and supplies them to consumers. These
are source-ownership groups, not shared Ruby namespaces. Synchronous APIs can
be called directly. Diagram links represent source references; calls through
injected objects require separate runtime review.

## Implemented phase: P1/P2/P3/P4 (`storage`)

P3 adds public VectorStore and Embeddings AsyncClients. Their synchronous
contracts and implementations have no Engine dependencies. See the
[public receiver migration](../migrations/vector-async-clients.md).

### P2: LLM

The LLM contract owns a model turn's inputs, results and validation; its backend
owns provider construction and translation. The execution client schedules the
complete synchronous operation through Execution.

For example, Agent supplies an `LLMAdapter::Request` to the internal client.
The selected backend creates its SDK objects inside `perform_complete`, and
Base validates the returned `LLMAdapter::Response` before Agent consumes it.

- Install the AST analyzer, group annotations, SVG formatter and boundary gate
  in `tools/architecture/`. The Architecture workflow checks the committed
  phase and generates evidence for its actual checkout SHA.
- `LLMAdapter::Base` defines synchronous `complete` and `stream` templates,
  identity and optional input budget. Backend extensions implement protected
  `perform_complete` and `perform_stream`; SDK chat construction, configuration
  and value translation stay private to the backend. The original P2 SPI was
  replaced by [ADR-066](../decisions/066-llm-and-tool-operation-contracts.md)
  and the [unit 6 migration](../migrations/r8-unit6.md).
- `LLMAdapter::AsyncClient` owns the internal `complete_async` and `stream_async`
  operations in `llm_adapter/async/`. It is not a public extension API.
- `LLMAdapter::RubyLLM` lives in `llm_adapter/backends/` and inherits Base.
  Its public constant and default-provider role remain; the current signatures
  use the typed operation contract introduced after the original P2 move.
- Zeitwerk collapses these two new directories. Neither `Phronomy::Async` nor
  `LLMAdapter::Async` / `LLMAdapter::Backends` is introduced.
- Agent constructs the framework client around the configured synchronous
  adapter. Custom adapters implement no async methods and need no pool logic.

The client preserves `on_full: :raise`, the original pool TaskResult, token
forwarding and per-chunk cancellation. Transport timeout/retry stays with the
adapter/provider. Construction starts no Runtime, and the default pool is
resolved again on each operation; an injected pool stays caller-owned. Only an
internal lightweight sink runs on the worker; Agent application event callbacks
continue to run on EventLoop.

Use `require "phronomy"` and the public constants. The old implementation path
`phronomy/llm_adapter/ruby_llm` moves to
`phronomy/llm_adapter/backends/ruby_llm`; arbitrary partial-load paths are not the
public loading contract. No shim in the contract directory reintroduces an
implementation dependency. The original P2 source move left public RBS and the
Stable/Beta snapshot unchanged. The subsequent unit 6 SPI replacement updates
both; that historical P2 result is not a promise about the current signatures.

### P3: VectorStore and Embeddings

Vector and embedding contracts own synchronous operation rules; their clients
add submission and completion without selecting a provider. Backends implement
protected hooks behind the inherited public validation templates.

For example, `Embeddings::AsyncClient#embed_async` submits `Base#embed`, which
validates text, calls `perform_embed`, and validates the returned vector. The
application can use that vector in a separate VectorStore operation.

- `VectorStore::AsyncClient` owns public add/search/remove/clear async operations;
  `Embeddings::AsyncClient` owns public `embed_async`.
- Backends implement only synchronous methods. The old `AsyncBackend` mixin
  and inherited async methods are removed; application callers change receiver.
- InMemory, Pgvector, RedisSearch and RubyLLMEmbeddings use `backends/`
  directories. The original P3 relocation preserved their bodies; subsequent
  [ADR-065](../decisions/065-vector-and-embeddings-common-operations.md) added
  common operation templates and the independent `Embeddings` namespace.
  See the [unit 5 migration](../migrations/r8-unit5.md) for the current SPI.
  Zeitwerk collapses `async/` and `backends/` paths within each feature.
- Synchronous RBS uses structural `_CancellationSignal`; async signatures keep
  TaskResult and the execution token. The public API snapshot records the new
  receivers and the intentional removals from Base/InMemory.
- All three original backend-to-Engine edges are removed. In the current
  annotated view, M28/M83 belong to G47 Contracts in B5. M67/M86 are clients in
  B4 and M71/M87 are separately grouped implementations. The old nested
  Embeddings module IDs are retired; no pending Storage clients are drawn.

### P4: Storage execution

Raw transaction submission and domain persistence work have different owners.
The Storage client schedules a backend transaction; a domain execution
environment schedules the domain's existing operation through Execution.

For example, a raw notes write uses `Storage::AsyncClient#transaction_async`.
An Agent terminal commit instead uses its Agent execution environment and keeps
commit/readback reconciliation in the Agent operation.

- Public `Storage::AsyncClient#transaction_async` opens the raw backend transaction
  on a worker and yields its scoped Storage::View. Backends stay synchronous.
- Domain units use their execution environments or `Execution.submit` directly,
  without a Storage forwarding helper or an extra transaction, timeout or token.
  The [execution inventory](storage-execution-boundaries.md) records 14 current
  submission sites in its six source files; it is not a framework-wide count.
- M69 is an Async Client and M35 a concrete Storage backend in B4.
  Existing `Storage::Backends` is not collapsed.
- See the [public API and transaction rules](../migrations/storage-async-client.md).

### ContentStore service ownership

ContentStore is a content management service using Storage, not a peer physical
backend. Its API, canonicalization, StoredContents implementation and owned
StorageSchema live in `content_store/`. Base remains shared by StoredContents
and the Persistence exception facade. The unnecessary `backends/` subdivision
and Zeitwerk collapse are removed without a forwarding file or alias.

M10 belongs to G57 Content Service in the persistence column of display band B3.
M73 is retired, not reused. G47/G48 contain no ContentStore modules. The real
M10-to-Storage dependency remains in both the drawing and the full graph.
The boundary gate rejects reverse Storage-to-ContentStore dependencies and any
service path to a physical backend, Engine, client or domain orchestration.
Public constants, signatures, content IDs, exceptions and transaction behavior
remain unchanged. See [ADR-062](../decisions/062-content-store-service.md).

## r8 unit 1 framework boundaries

G58/M76/M77 now owns the common Execution framework under `execution/`.
Engine owns FSM-specific values and the pool/timer/runtime binding, while
composition selects that binding. Tracing owns explicit observation. Context
and Tool now own their shared operations, not merely value/error declarations.
The former G59/M78 split is retired. See [r8 unit 1](r8-unit1.md) for the exact
implemented scope, API removals and incomplete Persistence/domain work.

As of 2026-11-28, G58/C13 also contains the private `RetainedAttempts` manager
and `AttemptCompletion` evidence record used by four Agent/Workflow recovery
owners. They consume an injected submitter and the existing owner mutex; domain
proof, application and release remain outside the shared layer. See
[shared retained-attempt management](retained-attempts.md).

The full architecture still contains existing cycles outside the checked scope.
The recorded graph is not an ideal final r8 diagram.

## Pending phase

P5 completes the final cross-repository/API/docs review after application.
The current candidate aligns public composition, async input declarations and
active guidance with the implemented responsibilities. It removes the unused
private Storage submission helper and the obsolete callback-test placeholder.

For example, the optional SQL package now obtains its canonical declarations
through `PersistenceComposition.resources`, then supplies the existing table
mappings and backend to composition. Agent-only backends use `agent_resources`.
Neither catalog selects a backend or starts execution.

The published 0.34.0 gem does not contain these catalog operations. Matching
source checkouts can be tested together, but P5 remains pending until a core
release containing the operations is published, all examples dependencies are
resolved against that release, and the applied commits pass their CI checks.
Do not use a private fallback or claim published-gem acceptance from a path
bundle. `phase.json` records this candidate and its remaining acceptance gates.

All retained P2-P4 responsibilities exist in source; the unnecessary M73 split
is superseded by G57 service ownership. The measured SVG still comes from
actual Ruby analysis; the target concept is a separate explanatory artifact.
Completing P5 does not close every r8 pending scope.

## Regenerate and review

See [tool instructions](../../tools/architecture/README.md). The normal command
reads `tools/architecture/phase.json`:

```sh
python tools/architecture/refresh_diagram.py . tmp/architecture
```

The output includes the matrix, source hashes, boundary report, module/file
cycles and the delta from baseline 84668606. Source/module/group changes require
matching annotation updates. No up/down rule or coordinate controls the gate.
Ruby loader, RBS, cancellation, admission, streaming and configuration tests
remain necessary: static analysis does not replace them.

An unpublished local candidate must use `--candidate`. Its SVG states that it
is unapplied and disables GitHub source links. Applied commits and CI output
use actual source links. CI artifacts are generated after the source commit;
there is no self-referential SVG commit hash or automatic commit/push.

Text panels are transparent and module outlines/group colors remain intact.
Arrows into M33/M41/M44 are hidden by presentation settings; their AST edges,
source evidence and matrix cells are preserved. Boundary rules inspect all edges.
