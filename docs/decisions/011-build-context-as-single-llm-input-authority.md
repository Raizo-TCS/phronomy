# ADR-011: build_context as the Single Authority for LLM Input

## Status

Proposed — 2026-05-31

## Context

### Background

`Agent::Base#build_context` was introduced as a hook for subclasses to customise
the system prompt and conversation history passed to the LLM.  Its original return
value was `{ system: String|nil, messages: Array }`, covering only two of the four
conceptual regions of an LLM context window.

`LlmContextWindow::Assembler` documents the four regions explicitly:

```
1. Instruction  — system prompt text
2. Capability   — tool definitions
3. Knowledge    — external facts (XML context tags)
4. Conversation — conversation messages
```

However, the Assembler itself states Region 2 is "handled by RubyLLM, not here",
leaving tool registration entirely outside the `build_context` path.

### Problems identified

**P1 — Tool definitions are not part of `build_context` output**

Tools were registered with `chat.with_tool(tc)` *after* `build_context` returned,
directly in `InvocationPipeline`, `_stream_impl`, and `ReactAgent#step`.
This means a subclass that overrides `build_context` cannot control which tools
are actually sent to the LLM; tools are always added behind its back.

**P2 — `_handoff_tools` bypass `build_context` entirely**

`Runner` adds handoff tools via `_add_handoff_tool` onto the agent instance.
These were registered with `chat.with_tool(tc)` at every call site, separately
from `context[:tool_classes]`, without going through `build_context` at all.
Even if a subclass override returned a modified tool list, handoff tools would
still be added unconditionally.

**P3 — Tool token cost excluded from budget calculation**

LLM providers (OpenAI, Anthropic, Gemini) count tool schema tokens against the
context window.  The `TokenBudget` / `Assembler` pipeline never subtracted tool
tokens from the available budget before trimming conversation messages.  This
caused the budget calculation to be consistently optimistic: the `effective_input_limit`
was always larger than the tokens actually available for messages, risking context
window overflow on long conversations with many or complex tools.

The existing `context_overhead` DSL was a manual workaround:

```ruby
class MyAgent < Phronomy::Agent::Base
  context_overhead 800  # developer guesses tool token cost
end
```

This is inaccurate by design and should not be necessary.

**P4 — RAG fetch called inside `build_context` on every invocation**

`build_context` called `fetch_knowledge_chunks` dynamically.  In a ReAct loop
with N iterations, RAG was fetched N times for the same query.  More importantly,
dynamic per-call RAG fetch is architecturally misplaced:

- Knowledge fetched by RAG and injected as Region 3 context belongs to the
  *agent's knowledge*, not to the per-invocation message flow.
- If the LLM needs to retrieve information dynamically, the correct mechanism is
  **function calling**: the LLM calls a retrieval tool, and the result appears in
  the conversation log as a tool result message (Region 4).
- Static knowledge that the agent always needs should be registered once at
  agent initialisation time, not re-fetched on every `build_context` call.

**P5 — `build_capability_tool_classes` is redundant indirection**

`build_capability_tool_classes` was introduced as a narrower override hook to
avoid requiring subclasses to copy `build_context` just to change tool selection.
However, it has no documentation, no usage examples, and provides no capability
that overriding `build_context` itself does not already provide.  Its existence
adds a public API surface and conceptual overhead without commensurate value.

**P6 — No access to previous context**

`build_context` builds from scratch every call with no knowledge of what was sent
to the LLM in the previous call.  This prevents:
- Token cache hit optimisations (OpenAI prompt caching, Anthropic `cache_control`)
  which require a stable prompt prefix
- Incremental context strategies that avoid recomputing unchanged regions

## Decision

### D1 — `build_context` is the single authority for all LLM input

**Nothing may be added to or removed from the LLM request outside of
`build_context`.**  Every call site (`InvocationPipeline`, `_stream_impl`,
`ReactAgent#step`, `ReactAgent#stream_step`) must:

1. Call `build_context` to obtain `{ system:, messages:, tool_classes: }`.
2. Apply the result to `chat` — and *only* the result.
3. Not register any additional tools, messages, or instructions independently.

### D2 — Assembler handles all four regions including Capability

`LlmContextWindow::Assembler` gains `add_capability(tool_classes)`:

```ruby
assembler.add_capability(tools)  # Region 2
```

Responsibilities of `add_capability`:

1. Store `tool_classes` for pass-through in `build` return value.
2. Serialise each tool's schema (via RubyLLM's provider-specific `tool_for` /
   `function_declaration_for`) and estimate its token cost.
3. Add that cost to the `used` token count before conversation message trimming.

`build` return value expands to:

```ruby
{ system: String|nil, messages: Array, tool_classes: Array }
```

### D3 — `build_context` includes all tools (user tools + handoff tools)

`build_context` passes `self.class.tools + _handoff_tools` to
`assembler.add_capability`.  `_handoff_tools` are framework-managed routing tools;
they are always included and are not subject to user-level filtering.

Subclasses that need dynamic tool selection override `build_context` and call
`assembler.add_capability` with their own selection logic.

`build_capability_tool_classes` is **removed** (P5 resolution).

### D4 — `fetch_knowledge_chunks` is removed from `build_context`

Knowledge enters Region 3 through exactly two paths:

**Path A — Agent initialisation (static knowledge)**

```ruby
class MyAgent < Phronomy::Agent::Base
  knowledge "The capital of Japan is Tokyo.", type: :entity
end
```

Registered once; the Assembler always includes it.

**Path B — Per-invocation dynamic knowledge via `config[:knowledge_sources]`**

The caller passes knowledge sources in the invocation config:

```ruby
agent.invoke(input, config: { knowledge_sources: [my_rag_source] })
```

`build_context` calls `fetch_knowledge_chunks` exactly **once per `invoke`**,
not once per LLM call within a ReAct loop.  The result is cached on the agent
instance for the duration of that invocation.

This is a caller responsibility: if the caller needs fresh knowledge on every
`invoke`, it passes new sources.  Within a single `invoke`, knowledge is stable.

### D5 — Previous context stored as instance variable

After each `build_context` call, the result is stored:

```ruby
@last_context = { system: ..., messages: ..., tool_classes: ... }
```

`build_context` may reference `@last_context` for optimisations such as:

- Detecting that `system` and `tool_classes` are unchanged → skip regeneration
  of the stable prefix to improve LLM provider token cache hit rate.
- Skipping Assembler work when the context is provably identical to the last call.

`@last_context` is **not** passed as a method parameter; it is read from the
instance.  This avoids changing call-site signatures.

Note: `Agent` instances are not thread-safe (already documented).  `@last_context`
inherits this constraint — concurrent invocations on the same instance are not
supported.

## Consequences

### Token budget accuracy

With D2, `effective_input_limit` correctly reflects the tokens actually available
for conversation messages after system prompt, tool schemas, and knowledge are
accounted for.  `context_overhead` becomes unnecessary for tool costs; it may
still be used as a manual reserve for provider-specific overhead not captured by
schema serialisation.

### `build_context` as the integration surface

Subclasses override `build_context` for all customisation: tool selection,
knowledge injection, system prompt variants, context compression strategies.
There is one integration point, not several.

### RAG fetch frequency

`fetch_knowledge_chunks` runs at most once per `invoke` call (P4 resolution).
In ReAct loops with N iterations, RAG is fetched once, not N times.

### Removed API

`build_capability_tool_classes` is removed.  It was never documented or used
outside of internal framework code, so there is no public API break.

## Migration notes

- All call sites (`InvocationPipeline`, `_stream_impl`, `ReactAgent#step/stream_step`)
  must be updated to remove the separate `_handoff_tools` registration lines and
  rely solely on `context[:tool_classes]`.
- `Assembler#add_capability` and the token estimation for tool schemas must be
  implemented.
- `build_context` must be updated to pass all tools to `assembler.add_capability`
  and to cache `@last_context`.
- `fetch_knowledge_chunks` must be lifted out of `build_context` into the
  invocation-scoped cache described in D4.
