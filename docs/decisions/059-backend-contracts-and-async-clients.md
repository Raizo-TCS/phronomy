# ADR-059: Backend Contracts, Implementations and Execution Clients

## Status

Accepted; P1/P2/P3/P4 (LLM, VectorStore, Embeddings, Storage/ContentStore and
diagram tooling) implemented. Final P5 review remains pending, as recorded in
[Backend responsibilities](../architecture/backend-groups.md).

ContentStore's classification and directory split are superseded by
[ADR-062](062-content-store-service.md): content management is a service over
Storage, outside Backend Contracts and Backend Implementations. The other
contract/client/backend separations remain in force.

Later contracts refine the client connection and LLM extension points without
merging their responsibilities. [r8 unit 1](../architecture/r8-unit1.md) places
submission behind Execution, and
[ADR-066](066-llm-and-tool-operation-contracts.md) replaces the SDK-shaped LLM
SPI with typed model-turn operations. For example, the LLM client submits a
Request through Execution; the backend constructs its SDK chat inside a protected
hook. Earlier claims about unchanged P2 signatures and RubyLLMMaterializer
below are historical and do not define the current SPI.

## Context

The synchronous LLMAdapter SPI and its RubyLLM implementation shared a directory
with private async methods that referenced Runtime. Adapter authors were told
to implement only synchronous methods, but Base still coupled the SPI to Engine.
Numbered diagram bands also implied an ordering between independent concerns.

## Decision

1. Use independent responsibility groups with stable identifiers. Engine,
   Contracts, Async Clients and Implementations are distinct; coordinates and
   group numbers do not define dependency permissions. For readability, restore
   the earlier B1-B6 horizontal display bands and topical columns; these are
   presentation metadata independent of the responsibility annotations. Place
   separated Contracts in B5, distinct from Engine, and Async Clients in B4.
   Keep Implementations separately grouped in B4; mark unsplit backends there
   as pending instead of presenting their contracts as already separated.
2. Keep `LLMAdapter::Base` synchronous. Move internal async wrappers into
   `LLMAdapter::AsyncClient`; Agent supplies its configured adapter to the client.
   The public SPI, configuration setting and RubyLLM constant remain unchanged.
3. Separate contract/client/implementation directories, using explicit Zeitwerk
   collapse to retain feature namespaces. Do not make a common Async namespace,
   add a Base-to-client factory, or install an include/prepend compatibility hook.
4. Implementations depend on Contracts. Contracts and implementations do not
   reference Engine or clients. Under the current Execution amendment, clients
   use Backend and Execution contracts without directly referencing Engine or
   selecting concrete providers. Engine implements the execution mechanism
   chosen by composition.
5. Preserve original TaskResult, non-waiting admission failure, token semantics,
   no additional operation timeout, provider-owned retries and EventLoop callback
   delivery. Resolve the default pool at operation time; do not cache it across
   Runtime resets. Explicit pool injection leaves lifecycle ownership to its owner.
6. Generate SVG and boundary evidence from each committed source revision.
   Maintain the individual module boxes, IDs, full dependency matrix and source
   evidence. A phase cannot declare completion while legacy dependencies remain.

The vector/embedding SPI and namespace clauses are amended by
[ADR-065](065-vector-and-embeddings-common-operations.md).

## Consequences

This supersedes the remaining LLM Base-to-Runtime coupling described in ADR-040.
The original P2 change retained ADR-027's synchronous provider-call boundary and
its then-SDK-shaped materialization caveat. ADR-066 later replaced that
materialization and extension SPI; the synchronous provider boundary remains.
P2 keeps the LLM client internal. P3 introduces public VectorStore/Embeddings
AsyncClients and moves async receivers off the synchronous backends. Their
argument conventions and execution semantics are unchanged; the receiver
migration is intentional and documented. Storage operations do not change in
P3. P4 adds public raw `transaction_async` and a private submit path for existing
Agent/Workflow/coordination units. The latter opens no transaction and leaves
uncertain-result policy with each owner. P4 originally moved ContentStore's
implementation into a backend directory; ADR-062 removes that unnecessary split
and classifies it as a content service. Other repository cycles remain visible.

Transparent module/caption panels and hidden incoming arrows to M33/M41/M44 are
presentation settings only. The full measured graph, matrix and boundary rules
remain unchanged by that filtering.

Boundary tests cover direct and indirect reverse dependencies and keep group
IDs independent from policy. Runtime tests cover sync-only custom adapters,
worker/EventLoop separation, rejection, exceptions, cancellation and Runtime
reset. CI produces artifacts with the actual source SHA rather than committing
a diagram containing its own commit hash.
