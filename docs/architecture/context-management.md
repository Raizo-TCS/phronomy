> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Context Management

## 1. Authority model

Phronomy separates canonical execution facts from the logical input of one LLM
Call.

```text
Observed execution facts / registered Knowledge / current-call material
        |
        v
JournalProjection + internal normalization
        |
        v
ContextPolicyInput
  instruction / knowledge / tools / conversation
        |
        v
ContextPolicy#call
        |
        v
ContextPlan
  instruction / knowledge / tools / conversation
        |
        v
ContextAssembler validation / canonicalization / final budget check
        |
        v
LLMInputManifest
        |
        v
RubyLLMMaterializer
```

- **Journal** is canonical append-only logical execution history.
- **ContextPolicyInput** is an immutable typed snapshot of material eligible for
  policy consideration.
- **ContextPlan** expresses the Policy's semantic selection/order/generation.
- **LLMInputManifest** is canonical logical input for one Provider Call.
- **RubyLLMMaterializer** realizes that Manifest against runtime Provider/Tool
  wiring; it is not another Context authority.

The normative Journal/Manifest split is
[ADR-012](../decisions/012-canonical-execution-log-and-context-policy.md).

## 2. Public Context Policy SPI

Application code supplies an ordinary reusable Ruby strategy object:

```ruby
class SearchContextPolicy < Phronomy::Agent::ContextPolicy
  def initialize(search:)
    @search = search
  end

  def call(input)
    plan(
      instruction: input.instruction,
      knowledge: @search.call(input.knowledge),
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

`context_policy` binds a **Policy instance** on the Agent class. Policy
construction/dependency injection are Application responsibilities. If the same
instance is shared by multiple Agents/classes, its concurrency safety is also an
Application responsibility.

There are no Policy overrides on Agent create/load/invoke/stream and no durable
Policy descriptor/registry. A currently loaded Application supplies the current
Policy code.

## 3. ContextPolicyInput

`ContextPolicyInput` has four top-level semantic collections:

```text
instruction
knowledge
tools
conversation
```

Instruction, Knowledge, Tool, and Conversation items are typed immutable values.

Conversation is an ordered outer Array of immutable non-empty inner Arrays. Each
inner Array is an indivisible selection group. Ordinary messages are singleton
groups. An assistant Tool Call and the matching Tool-role message(s) are one
atomic group and cannot be split by Policy selection.

Policy input also carries execution/call/model/budget information needed for
selection without exposing mutable Runtime state.

## 4. ContextPlan and Framework validation

The Plan uses the same four categories. Presence means selected; omission means
omitted; order within a category is semantically meaningful.

The Framework validates that:

- selected input items came from the immutable request;
- Policy-generated items use permitted generated-item rules;
- required material is retained;
- input conversation groups are not split, merged, or internally reordered;
- generated conversation Tool protocol is structurally valid;
- selected Tools resolve to the effective runtime Tool wiring;
- Framework-owned metadata cannot be forged by Application content; and
- the realized canonical input fits the final token budget.

Provider/Manifest structural placement remains `ContextAssembler`
responsibility.

## 5. Policy-generated / compacted material

An Application Policy may derive current-call material using the protected
instruction/knowledge/conversation item helpers. This is also the supported
shape for Application-defined semantic compaction:

```text
source optional Context
    |
Policy omits source item(s) for this call
    +
Policy creates derived current-call item
    |
ContextPlan
```

The original Journal facts are not deleted or rewritten. Generated content is
current-call material unless the Application explicitly persists equivalent
Knowledge through a separate supported mutation.

Phronomy does not provide a parallel mutable "Memory Compression" subsystem, a
fifth `derived` Plan collection, automatic summarization, or an extra built-in
LLM call for the Default Policy.

Required material cannot be silently compacted away. If required input cannot
be accepted/represented within the applicable invariants and budget, Context
preparation fails.

## 6. Default Policy

The built-in Default Policy is deterministic and model-free:

- retain instruction material in stable order;
- retain effective Tool definitions/order;
- retain required/current conversation;
- select an optional recent contiguous conversation window at group granularity;
- select Knowledge in stable order, skipping an oversized optional item and
  continuing;
- use an approximate 60% conversation / 40% Knowledge split for variable
  remainder and allow unused share to spill to the other category;
- perform no vector retrieval, embedding/reranking, or automatic compaction.

If required/fixed material does not fit, Context preparation fails rather than
silently dropping it.

## 7. Execution and Persistence boundary

`ContextPolicy#call` is synchronous and runs on the Agent preparation Offload
worker, not on EventLoop. No Phronomy Persistence transaction spans the Policy
call.

Preparation captures an immutable authoritative base, executes Application
Policy outside the durable transaction, then revalidates Agent/Execution
revision/watermark before the short commit/finalization path. A stale Policy
result fails closed rather than overwriting newer durable state.

Policy failure is not automatically retried and Phronomy does not silently fall
back to another Policy.

ContextPolicy is **not** one of the Framework's standard automatic tracing span
types. Policy-internal retrieval/transformation tracing is Application-owned.
See [Tracing](tracing.md).

## 8. Recovery

A finalized `LLMInputManifest` is the Recovery authority for the Provider input
it represents. Recovery hydrates that Manifest rather than rerunning the
historical Policy.

Future calls use the Policy supplied by the currently loaded Application code.
Agent/Workflow durability therefore does not depend on Policy object durability.

## 9. Security/trust policy

The Framework validates structure/integrity; it does not impose one universal
semantic trust policy on arbitrary Context.

Application-defined `ContextPolicy` is the semantic authority for source-aware
selection, rejection/failure, redaction/sanitization, retrieval, reranking, or
derived content needed for a particular LLM Call. Phronomy does not add a fourth
universal `context_filter` call site.

See [Security Boundaries](security-boundaries.md).

## 10. Removed intermediate contracts

The following are not current public Context Policy contracts:

- `ContextRequest`;
- `ContextPolicyDescriptor` / `ContextPolicyRegistry`;
- `DerivedContentSpec`;
- `ContextPlan#selected_unit_ids`;
- `ContextPlan#derived_contents`;
- `ContextPlan#ordering_hints`;
- `ContextPlan#policy_descriptor`;
- public `request.parts`;
- `Selection::Unit` / `Selection::Validator`;
- `DependencyAwareUnitBuilder`;
- `RequiredContextResolver`;
- `RecentFirstSelector`;
- `TokenBudgetPacker`.

Internal `Selection::Candidate` / `Selection::Constraint` normalization used
while building the typed request does not create an Application DSL.
