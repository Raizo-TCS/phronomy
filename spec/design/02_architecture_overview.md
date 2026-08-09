# Architecture Overview

> **Current architecture — Manifest-first stateful Agent model**

Phronomy separates durable execution facts from the logical input selected for
one provider call.

```text
Application / Agent execution
        ↓
Canonical append-only Agent Journal
        ↓
ContextCandidateResolver
        ↓
Context Policy
        ↓
validated ContextPlan
        ↓
Canonical LLMInputManifest
        ↓
RubyLLMMaterializer
        ↓
RubyLLM / Provider
```

## Authority boundaries

### Journal

The Agent Journal is the canonical append-only record of logical facts observed
or explicitly registered by Phronomy. Conversation messages, Tool protocol
messages, Knowledge, lifecycle/context reset markers, and execution facts are
recorded without rewriting old records.

### Context candidates

Not every Journal record is LLM input. `JournalProjection` exposes the records
eligible for Context selection, and `ContextCandidateResolver` converts them to
logical `ContextCandidate` values.

Persistent Knowledge is represented by ordinary Journal records with
`kind: :knowledge`. It is not a separate source-object hierarchy and it is not
part of the public transcript.

### Context Policy and ContextPlan

A `ContextPolicy` receives candidates plus budget/protocol information and
returns a `ContextPlan`. The default policy groups dependency-sensitive Tool
exchanges, marks required units, orders optional units, and packs them into the
available input budget.

Policy selection never deletes or edits the Journal.

### LLMInputManifest

`LLMInputManifest` fixes the logical input for one LLM call. It records the
selected segments, model configuration, Tool definitions and policy identity.
The runtime adapter must materialize exactly that Manifest.

### RubyLLMMaterializer

`RubyLLMMaterializer` converts a validated Manifest into RubyLLM runtime
objects. It is a projection layer, not another Context authority.

## Instructions, Knowledge and conversation history

These inputs intentionally have different semantics:

- **instructions** — framework/application-required system input;
- **Knowledge** — optional Agent-held Context candidates selected by policy;
- **conversation history** — canonical user/assistant/Tool messages selected by policy;
- **current user input** — required input for the current ask call;
- **Tool definitions** — required capability definition for the call.

Knowledge may be registered when an Agent is created or later through
`add_knowledge`. `clear_knowledge!` logically invalidates prior Knowledge
without deleting raw Journal records.

Per-call Context supplied through `before_llm_input` is not persisted. Its
`segment_candidates` enter the same Context Policy selection path as persistent
Knowledge and history.

## Persistence and lifecycle

`AgentRoot` contains durable Agent identity, revision, Journal position,
lifecycle state and transcript generation. Context mutations are serialized
through Persistence transactions and are rejected while an AgentExecution is
active or suspended where appropriate.

`clear_transcript!`, `clear_knowledge!` and `reset_context!` are logical reset
operations. They preserve append-only Journal history while changing which
records are eligible for future Context selection.

## Removed architecture

The following are not part of the current design:

- mutable RubyLLM message history as Agent state;
- `Agent#build_context` as an extension point;
- `LlmContextWindow::Assembler`;
- `ContextVersionCache`;
- `Memory::ConversationManager` as Agent Context authority;
- `StaticKnowledge` / `EntityKnowledge` / `KnowledgeSource` hierarchies;
- class-level static-Knowledge caches;
- Context pruning by deleting Journal history.

See `07_context_management.md`, ADR-012 and ADR-013 for the normative Context
and Knowledge decisions.
