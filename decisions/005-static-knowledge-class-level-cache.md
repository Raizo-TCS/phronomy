# ADR-005: static_knowledge Chunks Are Cached at the Class Level

## Status

Superseded by ADR-013.

This ADR records the historical decision for the former KnowledgeSource-based
architecture. `static_knowledge`, `KnowledgeSource`, `StaticKnowledge`,
`EntityKnowledge` and the class-level Knowledge cache are no longer part of the
active design.

## Context

`Agent::Base` supports `static_knowledge` — a list of `KnowledgeSource` objects
whose content is prepended to the system prompt on every invocation. Sources
declared as `static?` (e.g., `StaticKnowledge`) return content that never
changes at runtime.

Two caching strategies were considered:

1. **Instance-level cache**: each agent instance fetches and caches static chunks
   after first `invoke`.
2. **Class-level cache**: static chunks are fetched once per class and shared
   across all instances.

If agents are short-lived (created per-request), instance-level caching
provides no benefit — the cache is thrown away with the instance. A class-level
cache persists across request boundaries and is shared by all instances of the
same agent class, giving the same hit rate with less overhead.

## Decision

`static_knowledge` chunks from sources that return `static? == true` are
memoized in a class-level instance variable (`@_static_knowledge_cache`).
Non-static sources (e.g., `EntityKnowledge`, `RAGKnowledge`) are always
re-fetched on each invocation because their content depends on runtime state.

## Consequences

**Positive:**
- Eliminates redundant fetches for read-only knowledge bases in request-per-
  agent patterns.
- Memory is shared: all instances of a class point to the same chunk array.

**Negative / Tradeoffs:**
- If the underlying file or data changes while the process is running, the cache
  serves stale content. Applications that need live refresh must use a
  non-static knowledge source.
- In tests, the cache must be cleared between examples. `Phronomy.reset_runtime!`
  handles this.

## Supersession

ADR-013 replaces the source-object/cache model with Journal-backed persistent
Knowledge selected through Context Policy. The historical rationale above is
retained only to explain the superseded architecture.
