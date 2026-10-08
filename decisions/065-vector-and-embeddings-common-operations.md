# ADR-065: Vector and Embeddings common operations

Status: accepted for the authorized r8 unit 5 implementation. Actual-service
verification is reported separately from the design decision.

This amends ADR-059's vector/embedding extension and namespace provisions.
Its synchronous backend boundary, separate AsyncClients and no production worker
Threads rule remain in force. It implements C10/C11 and DP09/DP10 from the agreed
contract foundation target.

VectorStore::Base and Embeddings::Base own the public operation templates,
validation and cancellation checkpoint. Concrete backends override protected
perform_* hooks, retaining algorithms, database/SDK adaptation and physical state.
VectorStore does not require an embedding provider, and Embeddings does not depend
on VectorStore. Documents groups the existing Loader/Splitter helpers without
creating another domain Contract.

Placement is decided by domain meaning and observable rules, not shared use.
Generic reusable code does not become a Contract merely because multiple callers
need it. Database response parsing and SDK/serialization adaptation remain
implementation responsibilities even when several backends perform similar work.

Malformed public inputs fail before backend I/O. Malformed backend results fail
explicitly. Provider exceptions are adapted at the provider boundary, never by
rescuing arbitrary application failures in the common framework. No generic retry,
commit reconciliation or stronger concurrency guarantee is added.

Backends must reject malformed external data before converting it to the public
result. Redis RESP2 fields/counts/distances and Pgvector rows/JSON are decoded
inside their own backends, with `VectorStore::InvalidResultError` as the public
failure for invalid data. Legitimate absent metadata and Redis's documented
expired-document response are distinguished from corruption. The common Base
then validates the domain result; it contains no external-protocol decoder.

Old namespaces and public-template overrides are intentionally replaced without
compatibility aliases. Runtime API, RBS, contract tests, examples and migration
guidance move together. See [unit 5](../architecture/r8-unit5.md) and
[migration](../migrations/r8-unit5.md).
