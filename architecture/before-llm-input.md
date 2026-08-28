> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# before_llm_input

## 1. Purpose

`before_llm_input` is the supported request-scoped customization boundary before
a logical LLM input is finalized.

It may adjust model configuration and add logical Context candidates without
mutating Agent Journal state or a RubyLLM message buffer.

## 2. Registration tiers

Hooks may be configured globally, on an Agent class, or on one Agent instance.

```text
global -> class -> instance
```

Later model-configuration patches take precedence for the same key. Segment
candidates are accumulated in hook order.

## 3. Input and result

Hooks receive immutable `Phronomy::Agent::LLMInputBuildContext` metadata. They do
not receive a mutable Provider chat/message array.

A hook returns `Phronomy::Agent::LLMInputPatch` or `nil`.

```ruby
Phronomy::Agent::LLMInputPatch.new(
  model_config_patch: {temperature: 0.2},
  segment_candidates: [
    {
      category: :knowledge,
      role: :user,
      content: "request-scoped retrieved context"
    }
  ]
)
```

## 4. Context Policy boundary

`segment_candidates` are candidate material, not preselected Manifest segments.

They enter the same typed `ContextPolicyInput` path and may be selected, omitted,
or otherwise handled by Application Policy subject to Framework invariants.

Hook candidates are current-call material and are not automatically written to
Journal or persistent Knowledge.

## 5. Constraints

A hook must not:

- mutate Agent Journal state;
- mutate RubyLLM Chat/messages;
- assume an optional candidate will be selected;
- forge Framework-reserved Context metadata;
- bypass ContextPlan validation/canonicalization; or
- bypass final token-budget validation.

## 6. Trust/security

Phronomy does not reinterpret `input_filter` as a universal Filter over hook
candidates.

Application ContextPolicy may inspect hook candidate provenance/metadata and
apply domain-specific trust/security policy.

See [Security Boundaries](security-boundaries.md).
