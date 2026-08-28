> **CURRENT negative architecture guidance**
>
> This document records removed Agent Context/Memory designs that must not be
> mistaken for current contracts. Current architecture starts at
> [Agent Context](../agent-context.md) and
> [Context Management](../context-management.md).

# Removed Agent Context and Memory Architecture

## Mutable Provider chat as canonical state

RubyLLM/runtime message collections are projections/materializations, not
canonical Agent history. Canonical facts live in the append-only Journal and
each Provider input is fixed by an `LLMInputManifest`.

## Generic Memory subsystem

Phronomy does not use `Memory::ConversationManager`, `Memory::WindowMemory`,
`SummaryMemory`, or another mutable Memory object as Agent Context authority.

Long-context selection/derivation belongs to Context Policy.

## LlmContextWindow / ContextVersionCache

The removed window assembler/cache model is not a current extension boundary.
Context selection uses typed `ContextPolicyInput` and `ContextPlan`, with final
canonicalization/budget validation by `ContextAssembler`.

## Automatic history rewriting / Memory Compression

Phronomy does not delete or rewrite canonical Journal history to fit a model
window.

Application Policy may omit optional source items for one call and create
derived/compacted current-call content. Canonical source facts remain unchanged.

There is no separate current Memory Compression subsystem and no automatic
Default-Policy summarization LLM call.

## Static / Entity / RAG Knowledge hierarchy

Persistent Knowledge is Journal-backed logical Context, not a hierarchy of
source object classes. Retrieval/vector/entity extraction are acquisition
strategies owned by Application/Tool integrations.

## Removed Context selection DSLs

Not current public contracts:

```text
ContextRequest
ContextPolicyDescriptor
ContextPolicyRegistry
DerivedContentSpec
Selection::Unit
UnitBuilder / Selector / TokenBudgetPacker
ContextPlan#derived_contents
ContextPlan#ordering_hints
```

## Generic Agent session/thread identity

Agent Context is not keyed by a generic Application conversation/thread/session
identity. Phronomy uses purpose-specific logical/runtime operation identities.

## Cross-Agent shared history as Handoff

Semantic Handoff does not merge Journal histories or automatically copy all
Source history/Knowledge into Target durable state. It transfers policy-bounded
immutable Context and Target ContextPolicy still decides one-call input.

See [Multi-Agent Handoff](../multi-agent-handoff.md).
