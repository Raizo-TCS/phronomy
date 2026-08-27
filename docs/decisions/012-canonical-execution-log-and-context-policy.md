# 012 — Canonical Complete Execution Log and Context Policy

## Status

Accepted and implemented by the stateful Agent / ACS-04 Context Policy refactor.
This decision supersedes the legacy `build_context` / Assembler authority model and
the intermediate descriptor/registry-based Context Policy design.

## Decision

Phronomy records the logical execution facts it observes as an append-only Canonical
Complete Execution Log. Context selection, pruning, ordering, Tool subset selection,
and compaction do not rewrite or delete those raw facts. They decide only what is
materialized into one LLM Call Manifest.

Journal and Manifest are separate authorities:

- **Journal** is the authoritative record of logical execution facts observed by Phronomy.
- **Manifest** is the authoritative record of the logical input fixed for one LLM Call.
- Runtime Projection is derived from the Manifest and must not add semantic content that
  the Manifest did not select.

`agent_id`, `execution_id`, `llm_call_id`, `tool_call_id`, and Journal `sequence` retain
their narrow identity/provenance meanings. They are not generic Context-selection
boundaries. Tool protocol dependencies are represented as indivisible conversation
groups rather than by grouping all records from one execution.

## Context Policy semantic boundary

One LLM Call is prepared through:

```text
Context sources
  -> ContextPolicyInput
  -> ContextPolicy
  -> ContextPlan
  -> ContextAssembler validation/canonicalization
  -> LLMInputManifest
```

`ContextPolicyInput` exposes four top-level semantic categories:

```text
instruction
knowledge
tools
conversation
```

The values are immutable Phronomy-defined typed items. Conversation is exposed as an
ordered array of indivisible groups. An ordinary message is a singleton group; an
assistant Tool Call and its corresponding Tool-role message(s) form one atomic group.

`ContextPlan` uses the same four categories. Items omitted from the Plan are omitted from
that LLM Call. Plan ordering expresses Policy ordering within the Framework-owned
structural layout. ContextAssembler validates required material, group integrity, Tool
configuration, and the final token budget before it stores the Manifest.

A custom ContextPolicy is ordinary Ruby strategy code. It may select, omit, order,
compact, retrieve, or otherwise compute its Plan. Phronomy does not expose a public
Pipeline/Selector/UnitBuilder composition DSL as the Context Policy SPI.

## Agent binding and lifetime

A ContextPolicy is Application code/runtime wiring, not durable Agent state.

An Application binds a **ContextPolicy instance** on the Agent class:

```ruby
SEARCH_POLICY = SearchContextPolicy.new(vector_store: VECTOR_STORE)

class ResearchAgent < Phronomy::Agent::Base
  context_policy SEARCH_POLICY
end
```

If no Policy is bound, the built-in Default instance is used. There is no Policy override
on Agent instance creation/loading or on `invoke` / `stream` calls. A Policy instance may
be shared by multiple Agent classes; concurrency safety of a shared Policy and its runtime
dependencies is the Application's responsibility.

Phronomy does not persist or reconstruct a Policy instance and defines no
`ContextPolicyDescriptor`, Policy registry, serialized Policy config, or Policy version
contract. Recovery hydrates finalized `LLMInputManifest` values directly. Future Context
preparation after Recovery uses the ContextPolicy supplied by the currently loaded
Application code.

## Policy-generated material

A Policy may create new instruction, knowledge, or conversation items through the small
protected helper/factory API on `ContextPolicy`. Such material is an ordinary current-call
Plan item; there is no separate `DerivedContentSpec` collection.

Phronomy assigns current-call identity, estimates tokens, freezes/canonicalizes the value,
and stores content when needed by the finalized Manifest. The Application owns the
semantic transformation and any internal source mapping/provenance it requires. Merely
using a generated item in a Manifest does not promote it to a Journal fact or reusable
future Context candidate.

The ACS-04 Tool category is selection-only: a Policy may choose a subset of the effective
Agent Tool definitions but may not invent a runtime Tool implementation from schema-only
data.

## Default Context Policy

The built-in Default is deterministic and model-free:

- retain effective instructions in stable order;
- retain the effective Agent Tool configuration;
- retain required/current conversation and choose a contiguous recent optional history;
- choose Knowledge in stable order, skipping an oversized item and continuing with later
  items that fit;
- allocate variable remainder approximately 60% to conversation and 40% to Knowledge,
  allowing unused share to be reused by the other category;
- perform no automatic compaction, embedding search, reranking, or additional LLM Call.

If required/fixed Context cannot fit, preparation fails rather than silently deleting it.

## Execution / Persistence boundary

ContextPolicy executes synchronously on an OffloadPool worker, never on the Runtime
EventLoop. No Phronomy Persistence transaction spans `ContextPolicy#call`.

The required preparation shape is:

```text
capture authoritative local/durable snapshot
  -> build immutable ContextPolicyInput
  -> ContextPolicy#call outside Persistence transaction
  -> revalidate durable base/revision/lineage
  -> short commit transaction
       validate Plan
       canonicalize selected/generated content
       final budget validation
       store LLMInputManifest
       save execution state
```

A stale Policy result is rejected by the final revision/watermark precondition. Phronomy
does not automatically retry or fall back to another Policy after Policy failure.

## Consequences

- Agent/Workflow durability is independent of ContextPolicy durability.
- The Manifest, not the historical Policy implementation, is the Recovery authority for a
  finalized Provider input.
- Application Context strategies remain ordinary reusable Ruby objects with ordinary DI.
- Framework-internal protocol grouping/validation may use private helpers, but those
  helpers are not the Application Policy API.
- Replaced descriptor/registry/request/derived-content and selector-pipeline abstractions
  are removed rather than retained as compatibility aliases.
