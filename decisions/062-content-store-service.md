# ADR-062: ContentStore is a content service over Storage

- Status: Accepted
- Date: 2026-09-28
- Amends: ADR-059's ContentStore classification and source subdivision only.

## Context

ContentStore was grouped with synchronous backend contracts, and StoredContents
with physical backend implementations. InMemory and SQL instead implement
Storage::Backend. Composition always constructs StoredContents over that
backend's view. ContentStore adds content-derived IDs, canonical text/JSON and
digest verification; it is not another physical-storage selection point.

## Decision

Treat `content_store/` as a content management service. Move StoredContents from
`content_store/backends/` into this directory, next to Base and StorageSchema.
Delete the empty backend subdivision and its Zeitwerk collapse, without a
forwarding file, alias or alternative implementation-selection API.

Keep Base: both StoredContents and Persistence::ContentRepository use its shared
text/JSON operations. Keep ContentRepository: it translates known Storage
failures at the Persistence boundary. These classes are used responsibilities,
not obsolete backend scaffolding. StorageSchema is owned by the content service.

Retain the dependency from the service to neutral Storage. Storage owns physical
I/O, immutable blobs and transactions. The content service must not select a
physical backend or depend on Engine, Async Clients or domain orchestration;
Storage contracts and implementations must not depend on the content service.

## Compatibility and presentation

Public constants and RBS, private constant identities, content IDs, resource IDs,
database schema, exception behavior and root/transaction composition stay the
same. In particular, StoredContents' missing-content errors are still raw Storage
errors, translated by the Persistence facade. This change does not introduce an
independent ContentStore exception contract or alter commit uncertainty policy.

M10 moves to G57 Content Service, displayed in B3's persistence column. M73 is
retired and never reused. G47/G48 contain no ContentStore modules. Keep the
existing banded layout, group colors, module outlines, transparent text panels
and presentation-only common-arrow filters. Preserve every measured Ruby/RBS
edge, including the service-to-Storage edge; compare counts knowing that two
source directories have become one. Historical baseline evidence is immutable.

## Verification

Existing loading, content, Persistence conformance and transaction tests cover
the source move. The full Ruby + RBS boundary gate allows the intended Storage
dependency and rejects direct/indirect reverse or concrete-backend coupling.
The independent architecture regression also injects RBS-only violations.
