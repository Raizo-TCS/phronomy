# before_llm_input Hook

## Purpose

`before_llm_input` is the supported per-call customization boundary immediately
before a logical LLM input is assembled. It may adjust model configuration and
supply additional logical Context candidates without mutating Agent Journal
state or RubyLLM message history.

## Context

Hooks receive immutable `Phronomy::Agent::LLMInputBuildContext` metadata such
as Agent identity, definition identity, invocation config and call sequence.
They do not receive a mutable message array.

## Registration tiers

Hooks may be configured globally, on an Agent class, or on one Agent instance.
They run in this order:

```text
global → class → instance
```

## Return value

A hook returns `Phronomy::Agent::LLMInputPatch` or `nil`.

```ruby
Phronomy::Agent::LLMInputPatch.new(
  model_config_patch: {temperature: 0.2},
  segment_candidates: [
    {
      category: :knowledge,
      role: :user,
      content: "request-scoped context"
    }
  ]
)
```

Returning another type is an error.

Model configuration patches are merged in hook order, with later tiers taking
precedence for the same key. Segment candidates are appended in hook order.

## Context Policy boundary

`segment_candidates` are logical candidates, not preselected Manifest segments.
They enter the same Context Policy request as persistent Journal-backed Context.
Optional hook candidates may therefore be omitted under budget pressure.

Hook candidates are not written to the Journal and disappear after that LLM
call.

## Constraints

A hook must not:

- mutate Agent Journal state;
- mutate RubyLLM Chat/messages;
- assume its optional Context candidate is guaranteed to be selected;
- bypass Manifest validation or final token-budget validation.

For persistent information, use Agent `knowledge:` / `add_knowledge` instead.
