# ADR-059: Backend Contracts, Implementations and Execution Clients

## Status

Accepted; P1/P2/P3 (LLM, VectorStore and Embeddings separation plus diagram
tooling) implemented. Storage/ContentStore migration is pending, as recorded in
[Backend responsibilities](../architecture/backend-groups.md).

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
   reference Engine or clients; clients use Contracts and Engine through normal
   constant references or object injection, without selecting concrete providers.
5. Preserve original TaskResult, non-waiting admission failure, token semantics,
   no additional operation timeout, provider-owned retries and EventLoop callback
   delivery. Resolve the default pool at operation time; do not cache it across
   Runtime resets. Explicit pool injection leaves lifecycle ownership to its owner.
6. Generate SVG and boundary evidence from each committed source revision.
   Maintain the individual module boxes, IDs, full dependency matrix and source
   evidence. A phase cannot declare completion while legacy dependencies remain.

## Consequences

This supersedes the remaining LLM Base-to-Runtime coupling described in ADR-040.
ADR-027's synchronous public provider-call boundary and materialization caveat
still apply: this change does not make RubyLLMMaterializer provider-neutral.
P2 keeps the LLM client internal. P3 introduces public VectorStore/Embeddings
AsyncClients and moves async receivers off the synchronous backends. Their
argument conventions and execution semantics are unchanged; the receiver
migration is intentional and documented. Storage operations do not change in
P3. Other repository cycles remain visible.

Boundary tests cover direct and indirect reverse dependencies and keep group
IDs independent from policy. Runtime tests cover sync-only custom adapters,
worker/EventLoop separation, rejection, exceptions, cancellation and Runtime
reset. CI produces artifacts with the actual source SHA rather than committing
a diagram containing its own commit hash.
