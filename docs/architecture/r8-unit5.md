# r8 unit 5: VectorStore and Embeddings common contracts

Core baseline: `29818f5d0577ac5287c5429d6d169ef5fd1c0225`.
Examples baseline: `c410fc88112ad5e4648ba2e51335023885d9373b`.
The contract concept and foundation target remain the design goal. This unit
implements C10/C11 common operation ownership and DP09/DP10 placement. It does
not complete the other domain Contracts or the outstanding unit 4 acceptance gates.

## Ownership and completion conditions

Contract membership follows domain semantics, not frequency of reuse. A Contract
defines its domain's concepts, legal inputs/results, invariants, extension points
and observable failure/operation rules. Its framework executes those rules.
Code used by several callers is not automatically a Contract; a generic utility,
concrete adapter helper or composition operation can have several callers too.

| Placement decision in this unit | Domain reason |
| --- | --- |
| VectorStore id/vector/metadata inputs and ordered search results | These describe the public vector storage/retrieval operation independently of a database |
| Embeddings text/vector inputs and results | These describe text embedding independently of the provider SDK and downstream storage |
| Validation, pre-operation cancellation checkpoint and InvalidResultError | These enforce the operation's observable invariants and failure rules |
| Float-array normalization | This realizes the declared vector representation; it does not make arbitrary serialization a Contract concern |
| Redis RESP2 decoding, distance-to-similarity conversion, Pgvector row/JSON decoding | These are concrete backend adaptations and remain in the corresponding backend |
| Document loading/splitting | These are document utilities separated from VectorStore; this move does not create a new Contract |
| Async submission and timeout settlement | These remain Execution responsibilities, connected through each AsyncClient |

| Responsibility | Owner | Completion evidence |
| --- | --- | --- |
| Vector operation entry, cancellation checkpoint, input/result validation, chaining | `VectorStore::Base` | A hook-only custom backend receives validated inputs; malformed inputs perform no I/O; malformed outputs fail explicitly |
| Search/storage algorithms, physical dimension state, database encoding | `VectorStore::{InMemory,Pgvector,RedisSearch}` | Existing algorithm and adapter tests run through inherited public operations |
| Text input and finite embedding result validation | `Embeddings::Base` | A hook-only provider works without SDK, Engine or VectorStore; malformed outputs are rejected |
| Embedding provider call and SDK exception translation | `Embeddings::RubyLLMEmbeddings` | Provider exceptions retain their cause; cancellation and application failures retain their identity |
| Submission, timeout, admission and completion handle | Each feature's `AsyncClient` and Execution | Existing pool, cancellation, timeout and Runtime reset tests |
| Document input and splitting | `Documents::Loader` / `Documents::Splitter` | Existing document tests; no VectorStore or Embeddings dependency |

Common behavior lives in the existing Base classes. There is no forwarding
Contract, Base-to-client factory, compatibility alias or mandatory embedding
provider in VectorStore. Protected `perform_*` methods are the extension SPI;
applications call the inherited public operations. Ruby can override any method,
but overriding the public template is outside the documented backend SPI.

## Defined operation behavior

`VectorStore#add` checks cancellation, a String id, Hash metadata, a vector of
finite real numbers and the backend's known dimension before entering the
storage hook. It supplies a fresh Float array and returns the store. `remove`
and `clear` also return the store. A search validates input and positive `k`
before entering its hook, including an empty Redis store. Decimal strings for
`k` remain supported; fractional values no longer truncate silently.

Search results must be an Array of at most `k` Hashes with String `:id`, finite
numeric `:score`, Hash `:metadata`, and descending score order. A count must be
a non-negative Integer. Violations raise `VectorStore::InvalidResultError`.
Backend transport failures propagate without retries. Redis count failures no
longer become a successful zero count. Backend-specific index creation, metadata
encoding and query construction remain in the backend; they are not new common
storage primitives. Existing dimension-zero InMemory vectors remain supported.

Backends must not invent successful values while decoding malformed external
responses. RedisSearch validates its RESP2 count, field pairs, document keys,
numeric distances and JSON object metadata before producing the public result.
A genuine zero-match reply is `[0]`. A missing whole reply is invalid. Redis's
documented null document contents after expiration/update are omitted; they do
not imply a corrupt response, and the total can exceed the returned page size.
Missing/null Redis metadata and a SQL NULL metadata column still mean empty
metadata. Invalid JSON text, empty JSON text, JSON scalars/arrays and invalid
scores raise `InvalidResultError`. Pgvector also rejects invalid row ids rather
than turning them into strings. JSON parse failures preserve their original cause;
transport/database exceptions propagate unchanged and no read is retried.

The response decoders stay private to each backend. Base does not know Redis
commands, RESP versions, ActiveRecord rows, JSON columns or SDK exceptions.
The existing RESP2 support boundary and known-dimension/index initialization
requirements remain; this unit does not add RESP3 support.

Protocol references: [FT.SEARCH](https://redis.io/docs/latest/commands/ft.search/)
and [FT.INFO](https://redis.io/docs/latest/commands/ft.info/), checked 2026-10-03.

`Embeddings#embed` checks cancellation and String input, invokes `perform_embed`
once, and validates a non-empty finite vector before returning Float values.
Malformed output raises `Embeddings::InvalidResultError`. The RubyLLM backend
translates `RubyLLM::Error` to `Embeddings::TransportError`, preserving `cause`.
This error does not imply that external work was or was not accepted. There is
no automatic retry and no classification of an arbitrary application exception
as a provider failure.

Cancellation is cooperative. The common checkpoint occurs before the backend
operation; a provider may inspect the same signal during its work. A successful
write is not changed into cancellation by a post-write check. Timeout and result
settlement remain Execution responsibilities; an external call may continue.

Input errors are F0 failures before X0 I/O. For a write that has crossed X0,
failure/timeout is not proof of a rollback or of a missing external effect.
This unit adds no F1 outcome reconciliation, F4 recovery, cross-process exclusion
or exactly-once external-effect guarantee. InMemory dimension inference and
backend concurrency constraints retain their documented limits.

## Refactoring completion tracking

| Contracts | Current boundary status | Remaining work |
| --- | --- | --- |
| C10 VectorStore / C11 Embeddings | Common contract behavior implemented in unit 5 | Real Pgvector/Redis/provider service verification remains an implementation gate, reported separately |
| C05 Context / C07 Persistence / C08 ContentStore / C12 Storage / C13 Execution / C15 Tracing | Main common foundations implemented in units 1-4 | Additional domain acceptance conditions and overall dependency review are not waived |
| C09 LLM / C06 Tool | Partial | Public values/failures, SDK-neutral operation boundary, Tool SDK inheritance and execution connection |
| C04 Agent / C01 MultiAgent | Unit 4 ownership boundary implemented | FSM/Runtime/composition dependencies |
| C02 Workflow | Partial | FSM connection and durable child identity/resume/outcome reconciliation |
| C03 Generation / C16 Filter / C17 OutputParser | Existing common implementation | Finish responsibility-level conformity review; absence of certification is not evidence that all code is missing |

Next implement C09/C06 together where their SDK boundary interacts, then finish
C04/C01/C02 execution connections and durable collaboration. Inspect the existing
C03/C16/C17 implementations against explicit conditions before scheduling rewrites.

The package records commands actually executed and unexecuted backend gates.
See [migration](../migrations/r8-unit5.md) and
[ADR-065](../decisions/065-vector-and-embeddings-common-operations.md).
