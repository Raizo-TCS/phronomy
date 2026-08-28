> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Knowledge and RAG

## 1. Boundary

Phronomy separates information acquisition from Agent Context management.

```text
Application / Tool / retrieval pipeline
        |
        v
plain logical Knowledge content
        |
        +-- persist: Agent Journal (`kind: :knowledge`)
        |
        +-- request-scoped: before_llm_input candidate
        |
        v
ContextPolicyInput.knowledge
        |
        v
ContextPolicy
        |
        v
Manifest
```

Phronomy does not define a core hierarchy of `StaticKnowledge`,
`EntityKnowledge`, `RAGKnowledge`, or `KnowledgeSource` objects. How information
was obtained is not a Context-selection type.

Persistent Knowledge authority is defined by
[ADR-013](../decisions/013-journal-backed-knowledge-as-context-candidates.md).

## 2. Persistent Knowledge

Persistent Knowledge is registered on a live Agent:

```ruby
agent = ResearchAgent.new(
  knowledge: [
    "Account type: enterprise",
    "Data residency: Japan"
  ]
)

agent.add_knowledge(
  "Customer locale: ja-JP",
  metadata: {"origin" => "customer_profile"}
)
```

Content is stored through the durable content/Journal path and remains available
after Agent reload.

`clear_knowledge!` logically invalidates prior Knowledge for future Context
selection without deleting historical Journal records. `clear_transcript!` does
not clear Knowledge. `reset_context!` resets both relevant eligibility domains
without rewriting old Journal facts.

## 3. Request-scoped Knowledge

Information needed for only one LLM Call should not be persisted merely to make
it available to Context Policy.

`before_llm_input` may return an `LLMInputPatch` with a Knowledge
`segment_candidate`. The candidate enters the same typed Policy path and is not
automatically journaled.

See [before_llm_input](before-llm-input.md).

## 4. Retrieval paths

RAG can enter Agent reasoning through more than one ordinary application path.

### Tool-result retrieval

A Tool may query a VectorStore/external search system and return results to the
Agent. The Tool result participates in the normal Tool protocol and can influence
later Context through normal Journal/Context rules.

### Pre-Manifest retrieval

Application code may retrieve/rank content before Context finalization and supply
selected logical Knowledge through `before_llm_input` or an Application
`ContextPolicy`.

The core does not require one vector-retrieval lifecycle to be the universal RAG
path.

## 5. Vector/embedding responsibility

Vector stores, loaders, splitters, embeddings, ranking, and external retrieval
are acquisition/integration capabilities. They are not themselves durable Agent
Knowledge state.

An application may:

1. retrieve content;
2. rank/filter it;
3. convert it to plain logical Knowledge;
4. persist it with `add_knowledge`, or keep it request-scoped.

## 6. Selection and budget

Knowledge is optional by default. Context Policy decides whether it enters one
LLM Call and may omit it under budget pressure.

Information that is structurally required for the call must be represented
through the corresponding required Context mechanism; registration as Knowledge
does not make content mandatory merely by existence.

## 7. Trust/security boundary

Phronomy does not apply a universal semantic security Filter when Knowledge is
added or retrieved. Source validation, retrieval policy, ingestion sanitization,
and domain-specific trust decisions are Application/Tool responsibilities.

At one-call Context selection time, Application `ContextPolicy` may inspect
Knowledge provenance/metadata and decide whether to select, derive/sanitize, or
fail the preparation. Framework validation still enforces structural authority
and final Manifest invariants.

See [Security Boundaries](security-boundaries.md).
