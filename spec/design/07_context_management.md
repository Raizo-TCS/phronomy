# Phronomy — Context Management Design

## 1. Overview

This document specifies the Context Management subsystem: a set of components
that allow agents and graphs to operate correctly within finite LLM context
windows, regardless of how long a conversation grows.

### Problem Statement

An LLM's context window is a shared, finite token budget. It is consumed by:

1. **System instructions** — role, task, constraints
2. **Tool definitions** — JSON schemas for callable tools
3. **Injected knowledge** — RAG results, instruction files
4. **Conversation history** — user/assistant turns, tool outputs

The window also reserves space for the model's response
(**response headroom** = `model.max_output_tokens`).

```
context_window (total)
├─ max_output_tokens      (output reservation = model.max_output_tokens)
├─ overhead_reservation   (instructions + tool definitions, user-declared)
└─ effective_input_limit  (available for knowledge + conversation history)
```

Without deliberate management the window fills up, causing:
- API errors when the request exceeds the limit
- Silent context truncation by the provider
- Loss of earlier conversation turns / knowledge

### Design Goals

1. **Single source of truth for token budgets** — `Context::TokenBudget` derives
   limits from RubyLLM model metadata; explicit overrides are always possible.
2. **Centralised token estimation** — `Context::TokenEstimator` encapsulates the
   approximation logic (char/4 heuristic today, pluggable in future).
3. **Budget-aware Memory** — all `Memory::*` classes accept `token_budget:` in
   `load_messages` and return only as many messages as fit in the available space.
4. **Selective pruning** — `Memory::Pruner` provides a pluggable hook to drop
   low-value messages (large tool outputs, intermediate reasoning) before the
   budget check runs.
5. **Semantic retrieval** — `Memory::SemanticMemory` uses embeddings to return
   *relevant* messages rather than just the most recent ones.
6. **Composability** — `Memory::CompositeMemory` merges multiple memory sources
   within a shared budget.
7. **High-level assembly** — `Context::Builder` places instructions, knowledge,
   and conversation into the window in priority order.

---

## 2. Component Overview

```
Phronomy::Context
  ├── TokenEstimator       — centralised token estimation (char/4 heuristic)
  ├── TokenBudget          — derives effective_input_limit from model metadata
  └── Builder              — assembles context sections within budget (low priority)

Phronomy::Memory
  ├── Base                 — updated signature: load_messages(token_budget:, query:)
  ├── WindowMemory         — token-budget-aware sliding window
  ├── SummaryMemory        — token-budget-aware LLM compression
  ├── ActiveRecordMemory   — token-budget-aware DB-backed memory + pruner support
  ├── SemanticMemory       — embedding-based retrieval (medium priority)
  ├── CompositeMemory      — merge multiple memories within a shared budget (med.)
  └── Pruner
        ├── Base           — abstract pruner interface
        └── ToolOutputPruner — truncate oversized tool-call results

Phronomy::VectorStore
  ├── Base                 — abstract vector store interface
  └── InMemory             — cosine-similarity store backed by Ruby array

Phronomy::Agent::Base      — new DSL: max_output_tokens, context_overhead
```

---

## 3. Context::TokenEstimator

Central, stateless estimation module. All token counting in the framework
passes through here so it can be improved in one place.

### Interface

```ruby
module Phronomy::Context
  module TokenEstimator
    # Estimate tokens for a String or an Array of message-like objects.
    # @param input [String, Array] text or messages with #content
    # @return [Integer]
    def self.estimate(input)
      case input
      when String  then (input.length / 4.0).ceil
      when Array   then input.sum { |m| estimate(m.content.to_s) }
      else              0
      end
    end
  end
end
```

### Notes

- Current approximation: `ceil(char_count / 4)`.  Japanese text tends to use
  ~2 chars/token, while English uses ~4 chars/token; the heuristic is a
  conservative overestimate for English and a slight underestimate for Japanese.
- Future: replace with a model-specific tokenizer (e.g. `tiktoken` Ruby binding)
  by swapping this single method.

---

## 4. Context::TokenBudget

Derives the usable token space for conversation/knowledge from model metadata
stored in RubyLLM's `models_schema.json`.

### Initialisation

```ruby
# Auto-derive from RubyLLM model registry:
budget = Phronomy::Context::TokenBudget.new(
  model: "claude-3-5-sonnet-20241022"
)

# Or supply explicit values (useful for unknown / local models):
budget = Phronomy::Context::TokenBudget.new(
  context_window:   32_768,
  max_output_tokens: 4_096
)

# Optional overhead reservation for instructions + tool definitions:
budget = Phronomy::Context::TokenBudget.new(
  model: "gpt-4o",
  overhead: 800
)
```

### Key Accessors

| Method | Description |
|---|---|
| `context_window` | Total token limit of the model |
| `max_output_tokens` | Tokens reserved for output (`model.max_output_tokens` or explicit) |
| `overhead` | Tokens reserved for instructions/tools (default: 0) |
| `effective_input_limit` | `context_window - max_output_tokens - overhead` |
| `available(used: N)` | `effective_input_limit - N` (non-negative) |

### Error Handling

- Raises `Phronomy::Context::UnknownModelError` when `model:` is provided but
  not found in the RubyLLM registry and no explicit `context_window:` is given.
- `effective_input_limit` is always ≥ 0 (clamped).

---

## 5. Memory::Base — updated signature

The `load_messages` signature is extended with two optional keyword arguments.
Existing subclasses continue to work via `**_options` catch-all.

```ruby
def load_messages(thread_id:, token_budget: nil, query: nil, **_options)
```

| Parameter | Type | Meaning |
|---|---|---|
| `token_budget` | `Context::TokenBudget \| nil` | When present, limit messages to fit |
| `query` | `String \| nil` | Used by `SemanticMemory` for similarity search |

---

## 6. Memory::WindowMemory — token-budget support

When `token_budget:` is passed, the window becomes **token-based** rather than
message-count-based.

Algorithm:

```
messages ← @store[thread_id] (all, newest first)
if token_budget present:
  accumulate messages from newest until TokenEstimator.estimate(acc) > token_budget.effective_input_limit
  return accumulated messages in chronological order
else:
  return last(k * 2) messages  (existing behaviour)
```

---

## 7. Memory::SummaryMemory — token-budget support

`max_tokens:` is superseded when a `TokenBudget` is injected at construction
time. The compression threshold is then `token_budget.effective_input_limit`.

```ruby
SummaryMemory.new(
  token_budget: budget,    # optional; overrides max_tokens when set
  max_tokens:   4_000,     # fallback when no token_budget
  summarizer_model: "...", # optional
  keep_recent: 5           # messages kept verbatim after compression (default 5)
)
```

---

## 8. Memory::ActiveRecordMemory — token-budget + pruner support

`load_messages` gains two paths:

1. **`limit:` (existing)** — return the most recent N rows.
2. **`token_budget:` (new)** — load rows newest-first, accumulate until budget
   is exhausted, reverse to chronological order.

A `pruner:` can be attached at construction time. The pruner runs on the
selected messages *before* returning them.

```ruby
ActiveRecordMemory.new(
  model_class: PhronomyMessage,
  pruner: Phronomy::Memory::Pruner::ToolOutputPruner.new(max_output_tokens: 500)
)
```

---

## 9. Memory::Pruner

Pluggable transformation applied to a message list before the result is
returned from `load_messages`.

### Base interface

```ruby
module Phronomy::Memory::Pruner
  class Base
    # @param messages [Array] list of message-like objects
    # @param token_budget [Context::TokenBudget, nil]
    # @return [Array] pruned message list (same or shorter)
    def prune(messages, token_budget: nil)
      raise NotImplementedError
    end
  end
end
```

### ToolOutputPruner

Truncates tool-result messages whose content exceeds `max_output_tokens`.

```ruby
pruner = Phronomy::Memory::Pruner::ToolOutputPruner.new(max_output_tokens: 500)
# Any :tool role message with estimated tokens > 500 is truncated;
# a "(truncated)" suffix is appended to signal the cut.
```

---

## 10. Memory::SemanticMemory (medium priority)

Uses RubyLLM embeddings to find the most *semantically relevant* messages for
a given query, rather than merely the most recent ones.

```ruby
SemanticMemory.new(
  model_class:     PhronomyMessage,          # AR model for persistence
  embedding_model: "text-embedding-3-small", # passed to RubyLLM.embed
  vector_store:    Phronomy::VectorStore::InMemory.new,
  top_k:           10
)

# Usage (query: is the user's current input):
memory.load_messages(thread_id: "t1", query: "Ruby 3.4 features", token_budget: budget)
```

Algorithm on `load_messages`:
1. Load all messages for `thread_id` from the backing store.
2. Generate an embedding for `query`.
3. Score each message by cosine similarity to the query embedding.
4. Return the top-`k` messages sorted by score (highest first), filtered to fit
   within `token_budget`.

---

## 11. VectorStore

Abstract interface for embedding storage and similarity search.

### VectorStore::Base

```ruby
module Phronomy::VectorStore
  class Base
    def add(id:, embedding:, metadata: {}) = raise NotImplementedError
    def search(embedding:, top_k: 10)      = raise NotImplementedError  # → [{id:, score:, metadata:}]
    def delete(id:)                        = raise NotImplementedError
    def clear                              = raise NotImplementedError
  end
end
```

### VectorStore::InMemory

Pure-Ruby cosine similarity store. Suitable for development and small datasets.
No external dependencies.

---

## 12. Memory::CompositeMemory (medium priority)

Merges results from multiple memory sources within a shared token budget.

```ruby
CompositeMemory.new(
  memories: [
    { memory: semantic_mem, weight: 0.6 },  # weight = share of effective_input_limit
    { memory: window_mem,   weight: 0.4 }
  ]
)
```

On `load_messages`, each sub-memory receives a sub-budget proportional to its
weight. Duplicates (same content/role) are removed before returning.

---

## 13. Agent::Base — new DSL

Two new class-level DSL methods:

```ruby
class MyAgent < Phronomy::Agent::Base
  model "claude-3-5-sonnet-20241022"

  # Tokens to reserve for the response.
  # Default: model.max_output_tokens from RubyLLM registry (nil = use registry value).
  max_output_tokens 4_096

  # Tokens to reserve for system prompt + tool definitions.
  # Default: 0.
  context_overhead 800
end
```

`invoke` automatically builds a `TokenBudget` from these values and passes it
to `memory.load_messages`.

---

## 14. Context::Builder (low priority)

Assembles multiple context "sections" into a flat message list that fits within
a token budget. Sections have priorities; lower-priority sections are dropped
first when the budget is tight.

```ruby
builder = Phronomy::Context::Builder.new(budget: budget)
  .add(:system,   system_messages,   priority: :required)
  .add(:knowledge, rag_messages,     priority: :high)
  .add(:history,  history_messages,  priority: :normal)

final_messages = builder.build
# Returns all :required messages, then as many :high and :normal as fit.
```

---

## 15. Example: phronomy-examples/10_context_management

Demonstrates:
- `TokenBudget` construction from a model name
- `WindowMemory` with token_budget
- `SummaryMemory` with token_budget
- `ActiveRecordMemory` with token_budget + `ToolOutputPruner`
- `SemanticMemory` (if embedding model is available)
- `CompositeMemory`
- `Context::Builder`
- Agent DSL: `max_output_tokens`, `context_overhead`
