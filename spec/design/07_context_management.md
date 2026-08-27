# Context management design

> **Current design contract — four-category Context Policy + Manifest-first**

Historical execution facts and one-call LLM input are separate authorities.
Context Policy edits a typed immutable snapshot; it never rewrites the Journal.

## Authority model

```text
Observed execution facts / registered Knowledge / current-call material
        ↓
JournalProjection + internal candidate normalization
        ↓
ContextPolicyInput
  instruction / knowledge / tools / conversation
        ↓
ContextPolicy#call
        ↓
validated ContextPlan
  instruction / knowledge / tools / conversation
        ↓
ContextAssembler canonicalization + final budget validation
        ↓
LLMInputManifest
        ↓
RubyLLMMaterializer
        ↓
RubyLLM / Provider
```

- **Journal**: canonical append-only logical execution facts and persistent Agent
  Knowledge.
- **Manifest**: canonical logical input fixed for one specific LLM Call.
- **Runtime projection**: derived from the Manifest; not a new source of truth.

## Public Context Policy SPI

Application code defines ordinary reusable Ruby strategy objects:

```ruby
class SearchContextPolicy < Phronomy::Agent::ContextPolicy
  def initialize(search:)
    @search = search
  end

  def call(input)
    selected = @search.call(input.knowledge)
    plan(
      instruction: input.instruction,
      knowledge: selected,
      tools: input.tools,
      conversation: input.conversation
    )
  end
end

SEARCH_POLICY = SearchContextPolicy.new(search: SEARCH_SERVICE)

class ResearchAgent < Phronomy::Agent::Base
  context_policy SEARCH_POLICY
end
```

`context_policy` binds a **Policy instance** on the Agent class. The Application
owns Policy construction and dependency injection. If an instance is shared by
multiple Agent classes or live Agents, its concurrency safety and dependency
safety are Application responsibilities; Phronomy does not serialize shared
Policy calls.

There are no Policy overrides on Agent creation/loading or `invoke` / `stream`.
There is no durable Policy descriptor or registry.

## ContextPolicyInput

The input is immutable and has exactly four top-level semantic collections:

- `instruction`
- `knowledge`
- `tools`
- `conversation`

Instruction, Knowledge, Tool, and Conversation entries are Phronomy-defined typed
immutable values. Policy may inspect lower-level kind/provenance/metadata when it
needs them, but those details do not replace the four-category mental model.

Conversation is an ordered outer Array of immutable non-empty inner Arrays. Each
inner Array is an indivisible selection group. Ordinary messages use singleton
groups. Assistant Tool Calls and their corresponding Tool-role messages are
validated and grouped atomically by actual `tool_call_id` relationships.

## ContextPlan

The Plan uses the same four categories. Presence means selected; omission means
omitted. Output order within a category is the Policy's semantic order.

The Framework validates:

- selected items came from the immutable input or are permitted Policy-generated
  current-call items;
- required material is retained;
- input conversation groups are not split, merged, or internally reordered;
- generated conversation Tool protocol is structurally valid;
- Tool selection resolves to effective runtime Tool wiring;
- item identity is unambiguous;
- the realized canonical input fits the final token budget.

Provider/Manifest structural placement remains `ContextAssembler` responsibility.

## Policy-generated material

`ContextPolicy` provides small protected helpers for generating instruction,
Knowledge, and conversation items. A generated item is placed directly in the
ordinary Plan category; there is no `DerivedContentSpec` or fifth derived
collection.

Phronomy supplies current-call identity, token estimation, immutability/basic
validation, and Manifest canonicalization. Application code owns transformation
semantics and any internal source mapping/provenance it wants to retain.

Generated current-call content does not automatically become a Journal record or
a reusable future Context candidate. Cross-call cache/reuse/storage is
Application responsibility.

For ACS-04, the Tool category supports subset/order of the effective Tool
configuration. Schema-only creation of a brand-new runtime Tool is intentionally
not invented here because finalized-Manifest Recovery would require an additional
durable runtime-Tool identity/wiring contract.

## Default Policy

Default behavior is deterministic and does not invoke another model:

- instructions: retain stable order; no automatic compaction;
- Tools: retain effective configuration and order;
- current/required conversation: retain;
- optional conversation: choose a recent contiguous window at group granularity
  and realize chronologically;
- Knowledge: stable-order fit selection; skip an oversized item and continue;
- variable remainder: approximately 60% conversation / 40% Knowledge, with
  unused share reusable by the other category;
- no vector retrieval, reranking, embeddings, or automatic compaction.

If required/fixed material does not fit, Context preparation fails rather than
silently dropping it.

## Execution, Persistence, tracing, and Recovery

`ContextPolicy#call` is synchronous and executes on the existing Agent preparation
Offload worker. Policy may therefore perform blocking Application work, but it
must not block EventLoop.

No Phronomy Persistence transaction spans Policy execution. The Policy runs on an
immutable snapshot, then the short commit path revalidates durable Agent/Execution
revision/watermark before canonicalizing/storing the Manifest and persisting the
state transition.

Phronomy traces the Policy invocation boundary by default using non-content
metadata such as Agent/Execution/call identity and category counts. It does not
put full `ContextPolicyInput` or `ContextPlan` content into the standard trace.
Policy-internal retrieval/selection/transformation tracing is Application
responsibility.

A finalized `LLMInputManifest` is the Recovery authority for that Provider input.
Recovery does not rerun Context Policy to reconstruct it. Future Context
preparation uses the Policy supplied by the currently loaded Application code.
Agent and Workflow durability therefore do not depend on Policy durability.

## before_llm_input

`before_llm_input` may return `LLMInputPatch` with model-configuration changes or
logical `segment_candidates`. Per-call candidates are not automatically persisted;
they enter the same Policy input and may be selected/omitted according to Policy
semantics and Framework invariants.

## Removed intermediate contracts

ACS-04 removes rather than aliases the intermediate Context selection SPI:

- `ContextRequest`
- `ContextPolicyDescriptor`
- `ContextPolicyRegistry`
- `DerivedContentSpec`
- `ContextPlan#selected_unit_ids`
- `ContextPlan#derived_contents`
- `ContextPlan#ordering_hints`
- `ContextPlan#policy_descriptor`
- public `request.parts`
- `Selection::Unit` / `Selection::Validator`
- `DependencyAwareUnitBuilder`
- `RequiredContextResolver`
- `RecentFirstSelector`
- `TokenBudgetPacker`

The internal `Selection::Candidate` / `Selection::Constraint` normalization used
while constructing `ContextPolicyInput` is not an Application Context Policy DSL.
