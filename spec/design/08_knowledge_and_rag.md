# Knowledge and RAG

## Scope

Phronomy separates **information acquisition** from **Agent Context
management**.

```text
Application / Tool / RAG pipeline
        ↓ acquire / generate / extract
plain logical Knowledge content
        ↓
Agent Journal or before_llm_input
        ↓
ContextCandidate
        ↓
Context Policy
        ↓
Manifest
```

## Knowledge model

Phronomy has one Knowledge representation: a logical `:knowledge` Context
candidate.

There is no core hierarchy of StaticKnowledge, EntityKnowledge, RAGKnowledge or
KnowledgeSource objects. How information was obtained is not a Context-selection
type.

Persistent Knowledge is registered on an Agent instance:

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

The content is stored in ContentStore and referenced by an append-only Journal
record. Application metadata may carry provenance, but Phronomy does not give a
special semantic meaning to a `source:` field or expose it through custom XML.

## Lifetime

Persistent Knowledge survives Agent reload because it is Journal-backed.

`clear_knowledge!` logically invalidates earlier Knowledge for future Context
selection while retaining raw Journal records. `clear_transcript!` does not
clear Knowledge. `reset_context!` clears eligibility for both.

## Per-call Knowledge

Information needed only for one LLM call should not be persisted merely to make
it available to Context assembly. Applications may return a Knowledge candidate
from `before_llm_input`:

```ruby
agent.before_llm_input = ->(_ctx) {
  Phronomy::Agent::LLMInputPatch.new(
    segment_candidates: [
      {
        category: :knowledge,
        role: :user,
        content: "temporary retrieved context"
      }
    ]
  )
}
```

These candidates enter Context Policy but are not appended to the Journal.

## RAG responsibility

Vector stores, loaders, splitters, embeddings, ranking and external retrieval
remain useful capabilities, but they are not themselves Agent Knowledge state.

An application or Tool may:

1. retrieve documents from a VectorStore;
2. rank/filter them;
3. turn the selected result into plain logical content;
4. either persist it with `add_knowledge` or supply it per-call through
   `before_llm_input`.

This keeps retrieval strategy independent from durable Agent Context semantics.

## Entity extraction responsibility

Entity extraction follows the same rule. If an application derives
`"Customer name: Alice"` from conversation or another data source, it decides
whether that fact should be persisted as Knowledge. Phronomy does not maintain
an EntityKnowledge parser or automatically mutate Knowledge from messages.

## Selection and budget

Knowledge is optional by default. It is selected by the same Context Policy as
other optional Context candidates and may be omitted when the input budget is
insufficient.

Mandatory information belongs in instructions or another explicit required
Context mechanism; Knowledge does not become mandatory merely because it was
registered.
