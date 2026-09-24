# Backend responsibilities and asynchronous execution clients

The diagram uses responsibility **groups**, not numbered layers. `G14`, `G46`,
`G47` and `G48` are stable identifiers. Their numbers and positions do not define
abstraction levels or dependency permissions. Each source directory keeps its
own module box and stable module ID.

| Group | Responsibility | Dependency rule |
|---|---|---|
| G14 Engine | Runtime, workers, TaskResult, EventLoop | No feature-specific backend or client dependencies |
| G46 Async Clients | Execute synchronous backend operations through Engine | Use Contracts and Engine; do not select concrete backends |
| G47 Backend Contracts | Synchronous SPI, values, errors and shared rules | No Engine, Async Client or concrete implementation dependencies |
| G48 Backend Implementations | Implement the synchronous backend SPI | Depend on the corresponding Contracts; no Engine or client dependencies |

Composition chooses concrete backends and supplies them to consumers. These
are source-ownership groups, not shared Ruby namespaces. Synchronous APIs can
be called directly. Diagram links represent source references; calls through
injected objects require separate runtime review.

## Implemented phase: P1/P2 (`llm`)

- Install the AST analyzer, group annotations, SVG formatter and boundary gate
  in `tools/architecture/`. The Architecture workflow checks the committed
  phase and generates evidence for its actual checkout SHA.
- `LLMAdapter::Base` defines only synchronous `complete` and `stream`.
- `LLMAdapter::AsyncClient` owns the internal `complete_async` and `stream_async`
  operations in `llm_adapter/async/`. It is not a public extension API.
- `LLMAdapter::RubyLLM` lives in `llm_adapter/backends/` and still inherits Base.
  Its public name, synchronous signatures and default configuration are unchanged.
- Zeitwerk collapses these two new directories. Neither `Phronomy::Async` nor
  `LLMAdapter::Async` / `LLMAdapter::Backends` is introduced.
- Agent constructs the framework client around the configured synchronous
  adapter. Custom adapters implement no async methods and need no pool logic.

The client preserves `on_full: :raise`, the original pool TaskResult, token
forwarding and per-chunk cancellation. Transport timeout/retry stays with the
adapter/provider. Construction starts no Runtime, and the default pool is
resolved again on each operation; an injected pool stays caller-owned. Only an
internal lightweight sink runs on the worker; application event callbacks
continue to run on EventLoop.

Use `require "phronomy"` and the public constants. The old implementation path
`phronomy/llm_adapter/ruby_llm` moves to
`phronomy/llm_adapter/backends/ruby_llm`; arbitrary partial-load paths are not the
public loading contract. No shim in the contract directory reintroduces an
implementation dependency. No public RBS or Stable/Beta API snapshot changes
are needed in this phase; both are verified unchanged.

## Pending phases

P3 moves VectorStore/Embeddings async calls into feature-specific public
AsyncClients and separates their implementations. Their two old Runtime edges
are explicitly expected during P2. P4 introduces the Storage execution client
and separates StoredContents; transaction scope and domain outcome policy
must remain intact. P5 completes cross-repository API/docs/verification.

The complete target concept therefore includes modules not implemented yet.
The measured SVG always reflects actual Ruby source and marks the remaining
mixed directories. It never inserts planned modules into an AST result.

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
