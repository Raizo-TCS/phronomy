# ADR-013: Journal-backed Knowledge as Context Candidates

## Status

Accepted.

## Context

The Manifest-first Agent refactor established the Journal as the canonical
append-only record of Agent state and `LLMInputManifest` as the authority for
one provider call. The older Knowledge design remained outside that model:
`StaticKnowledge` and other `KnowledgeSource` objects were fetched separately,
then concatenated into the mandatory system prompt. That created several
problems:

- static/entity/RAG distinctions described acquisition strategy rather than
  Context semantics;
- class-level and instance-level Knowledge followed different storage paths;
- persistent Knowledge did not share Agent persistence/reload semantics;
- Knowledge bypassed Context Policy and was always mandatory once configured;
- `static?`, `source`, fetch/caching APIs and EntityKnowledge behavior existed
  primarily to support the obsolete source abstraction.

Applications still need two different lifetimes:

1. information that becomes durable Agent Knowledge at creation time or later;
2. request-scoped information used for only one LLM call.

## Decision

Phronomy has one Knowledge Context category.

### Persistent Knowledge

Persistent Knowledge is stored as ordinary append-only Journal records with
`kind: :knowledge`, `channel: :context`, `role: :user` and
`context_candidate: true`. Content lives in ContentStore and the Journal holds
its content reference and application metadata.

Agent instances accept Knowledge at creation and after creation:

```ruby
agent = MyAgent.new(knowledge: ["Policy: ..."])
agent.add_knowledge("Customer locale: ja-JP")
```

`Agent.load` requires no separate Knowledge source reconstruction because the
records are already persisted with the Agent.

### Selection

Knowledge is not part of the public conversation transcript.
`JournalProjection` exposes active Knowledge together with active transcript
records for Context selection. `ContextCandidateResolver` and Context Policy
therefore handle persistent Knowledge through the same selection pipeline as
other optional Context.

Knowledge is optional by default. The fact that content is Knowledge does not
make it mandatory.

Selected Knowledge is materialized before ordinary conversation-history
segments so that persistent background Context is not interleaved into the
middle of dialogue chronology.

### Reset semantics

`clear_knowledge!` appends a `knowledge_cleared` marker. Earlier Knowledge
records remain in the Journal but are excluded from later Context projections.
No Knowledge-generation counter is required.

`clear_transcript!` affects conversation history only. `reset_context!` resets
both transcript eligibility and Knowledge eligibility while retaining raw
Journal records.

### Per-call Context

`before_llm_input` continues to accept `LLMInputPatch#segment_candidates`.
Those candidates are not persisted. They enter the same Context Policy request
as Journal-backed candidates and may be omitted when optional and over budget.

### Acquisition responsibility

Phronomy core does not model `StaticKnowledge`, `EntityKnowledge`,
`RAGKnowledge` or `KnowledgeSource` subclasses. File loading, retrieval, entity
extraction and other acquisition strategies belong to applications or Tools.
Once an application chooses to retain the resulting information, it registers
plain logical Knowledge with the Agent.

## Consequences

### Positive

- one persistent representation and one Context-selection path;
- creation-time and post-creation Knowledge behave identically;
- durable Knowledge naturally survives Agent reload;
- token-budget selection can omit optional Knowledge without rewriting state;
- RAG/entity extraction can evolve independently of Agent Context persistence;
- no class-level static cache or `static?` distinction is needed.

### Tradeoffs

- applications that previously declared class-level static Knowledge must pass
  common Knowledge when constructing each Agent instance;
- source-specific refresh behavior is no longer a framework abstraction;
- provenance that matters to an application must be stored explicitly in
  metadata rather than through a dedicated `source:` API.

## Removed contracts

This decision removes the active contracts for:

- `Phronomy::KnowledgeSource`;
- `Agent::Context::Knowledge::Base`;
- `StaticKnowledge`;
- `EntityKnowledge`;
- `static_knowledge`, `static_knowledge_sources`, `static_knowledge_chunks`,
  `static_knowledge_refresh!`;
- `add_knowledge_source`, `instance_knowledge_chunks`;
- `clear_memory!` / `memory_generation` as obsolete Agent Context concepts.

ADR-005 is superseded by this decision. ADR-012 remains the authority for the
Journal/Manifest separation and Context Policy model.
