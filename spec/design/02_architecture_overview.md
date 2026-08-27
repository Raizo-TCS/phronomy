# Architecture Overview

> **Current architecture — Manifest-first stateful Agent model**

Phronomy separates durable execution facts, Application Context editing code,
and the logical input finalized for one Provider call.

```text
Application / Agent execution
        ↓
Canonical append-only Agent Journal
        ↓
Context candidate normalization
        ↓
ContextPolicyInput
        ↓
ContextPolicy
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

### Context Policy input

Not every Journal record is LLM input. `JournalProjection` and the internal
candidate resolver normalize eligible facts together with current-call material
into an immutable `ContextPolicyInput`.

The Application-facing input has four semantic categories:

```text
instruction
knowledge
tools
conversation
```

Conversation is an ordered array of indivisible groups. Ordinary messages are
singleton groups. An assistant Tool Call and the Tool-role message(s) answering
it are one atomic group.

### ContextPolicy and ContextPlan

A reusable Application `ContextPolicy` is ordinary synchronous Ruby strategy
code. It selects, omits, orders, retrieves, or compacts semantic material and
returns an immutable `ContextPlan` with the same four categories.

The Policy is bound as an Application-constructed instance on the Agent class:

```ruby
class ResearchAgent < Phronomy::Agent::Base
  context_policy RESEARCH_CONTEXT_POLICY
end
```

If no binding is declared, the built-in Default Policy is used. There are no
create/load/invoke/stream Policy overrides.

Policy selection never deletes or edits the Journal. Policy-generated current-
call content is canonicalized into the Manifest but does not automatically
become a Journal fact or a future Context candidate.

### LLMInputManifest

`LLMInputManifest` fixes the logical input for one LLM call. It records the
realized segments, model configuration, and selected Tool definitions. It does
not persist a ContextPolicy object, descriptor, registry key, or per-decision
Policy provenance log.

Recovery of a finalized Provider input hydrates the Manifest directly instead
of rerunning the historical Policy.

### RubyLLMMaterializer

`RubyLLMMaterializer` converts a validated Manifest into RubyLLM runtime
objects. It is a projection layer, not another Context authority. Tool subset
selection is materialized against the effective Application Tool wiring.

## Default Context Policy

The built-in Default is deterministic and model-free:

- retain effective instructions;
- retain effective Tool definitions;
- retain current/required Context;
- choose recent conversation history at indivisible-group granularity;
- choose Knowledge in stable order, skipping oversized items and continuing;
- split variable remainder approximately 60% conversation / 40% Knowledge and
  reuse unused share across the two categories;
- perform no automatic compaction, embedding search, reranking, or extra LLM
  call.

The final canonical Manifest is independently validated against the resolved
input token budget.

## Persistence and execution boundary

`ContextPolicy#call` executes synchronously on the Agent preparation worker and
must not run on EventLoop. No Phronomy Persistence transaction spans the Policy
call.

Preparation follows this boundary:

```text
capture authoritative snapshot
  -> build ContextPolicyInput
  -> run ContextPolicy outside Persistence transaction
  -> revalidate durable Agent/Execution base
  -> short commit transaction
       validate ContextPlan
       canonicalize content
       finalize token budget
       store Manifest
       persist Execution transition
```

A stale Policy result therefore cannot commit over a changed durable base.
Policy failure aborts Context preparation; Phronomy does not automatically retry
or switch to another Policy.

## Knowledge and context mutation

Persistent Knowledge is represented by ordinary Journal records with
`kind: :knowledge`. It is not a separate source-object hierarchy and it is not
part of the public transcript.

Knowledge may be registered when an Agent is created or later through
`add_knowledge`. `clear_knowledge!` logically invalidates prior Knowledge
without deleting raw Journal records. `clear_transcript!` and `reset_context!`
likewise preserve append-only historical facts while changing future eligibility.

Per-call material supplied through `before_llm_input` enters the same Policy
input path and is not automatically journaled.

## Removed architecture

The following are not part of the current design:

- mutable RubyLLM message history as Agent state;
- `Agent#build_context` as an extension point;
- `LlmContextWindow::Assembler` and `ContextVersionCache`;
- `Memory::ConversationManager` as Agent Context authority;
- Static/Entity Knowledge source hierarchies and class-level caches;
- Context pruning by deleting Journal history;
- `ContextRequest`, `ContextPolicyDescriptor`, `ContextPolicyRegistry`;
- `DerivedContentSpec` / `ContextPlan#derived_contents`;
- public Policy `parts` / UnitBuilder / Selector / TokenBudgetPacker composition.

See `07_context_management.md`, ADR-012 and ADR-013 for the normative Context
and Knowledge decisions.
