# Phronomy — Memory Compression

## 1. Overview

`Memory::Compression` provides strategies for reducing the token footprint of
conversation history before it is sent to the LLM. Compression is pluggable and
composable; multiple compressors can be chained.

```ruby
Phronomy.configure do |c|
  c.memory_compression = [
    Phronomy::Memory::Compression::ToolOutputPruner.new,
    Phronomy::Memory::Compression::Summary.new(model: "gpt-4o-mini")
  ]
end
```

Compression is applied by `ConversationManager` each time it assembles the
message list to send to the LLM.

---

## 2. Class Hierarchy

```
Phronomy::Memory::Compression::Base
├── Phronomy::Memory::Compression::Summary
└── Phronomy::Memory::Compression::ToolOutputPruner
```

---

## 3. Compression::Base

`lib/phronomy/memory/compression/base.rb`

Abstract base class. Subclasses implement:

```ruby
def compress(messages) → { messages: Array, compaction: Hash }
```

| Return key | Type | Description |
|------------|------|-------------|
| `messages` | `Array` | The compressed message list |
| `compaction` | `Hash` | Metadata about what was compressed (`removed_count`, `summary`, etc.) |

---

## 4. Compression::Summary

`lib/phronomy/memory/compression/summary.rb`

Summarises the oldest portion of the message history when the estimated token
count exceeds `max_tokens`. The most recent `keep:` messages are always
preserved verbatim.

### Constructor

```ruby
Phronomy::Memory::Compression::Summary.new(
  max_tokens:       4000,          # Integer — trigger threshold (default: 4000)
  keep:             10,            # Integer — recent messages to preserve (default: 10)
  summarizer_model: "gpt-4o-mini" # String  — model used for summarisation
)
```

### Compress logic

1. Estimate token count of all messages (1 token ≈ 4 chars, rough heuristic).
2. If total < `max_tokens`, return messages unchanged (`compaction: {}`).
3. Split messages into `old = messages[0..-(keep+1)]` and `recent = messages[-keep..]`.
4. Send `old` to `summarizer_model` with the prompt:
   ```
   Summarize the following conversation history concisely, preserving key facts:
   <messages as text>
   ```
5. Replace `old` with a single synthetic `:system` message:
   ```
   [Conversation summary]: <summary text>
   ```
6. Return `{ messages: [summary_message] + recent, compaction: { removed_count: old.size, summary: ... } }`.

### Idempotency

If the oldest message already contains `[Conversation summary]:`, the summary is
refreshed rather than stacked.

---

## 5. Compression::ToolOutputPruner

`lib/phronomy/memory/compression/tool_output_pruner.rb`

Stateless compressor that truncates long tool result messages. Does not call
the LLM.

### Constructor

```ruby
Phronomy::Memory::Compression::ToolOutputPruner.new(
  max_chars: 4000   # Integer — max characters per tool result (default: 4000)
)
```

### Compress logic

For each message with `role == :tool`:
- If `content.length > max_chars`, truncate to `max_chars` and append
  `"\n[... output truncated ...]"`.

Returns `{ messages: processed, compaction: { truncated_count: N } }` where
`N` is the number of messages that were truncated.

---

## 6. Integration with ConversationManager

`ConversationManager` applies compressors in order before adding a new user
message:

```ruby
def compressed_history
  compressors.reduce(messages) do |msgs, compressor|
    result = compressor.compress(msgs)
    @last_compaction = result[:compaction]
    result[:messages]
  end
end
```

The `@last_compaction` data is available for logging/metrics but is not exposed
in the public API.

---

## 7. Chaining Example

```ruby
pruner  = Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 2000)
summary = Phronomy::Memory::Compression::Summary.new(
  max_tokens: 3000,
  keep:       8,
  summarizer_model: "gpt-4o-mini"
)

# ToolOutputPruner runs first (cheap, no LLM), Summary runs second
Phronomy.configure { |c| c.memory_compression = [pruner, summary] }
```

---

## 8. Custom Compressor

```ruby
class MyCompressor < Phronomy::Memory::Compression::Base
  def compress(messages)
    # Remove all tool messages entirely
    kept = messages.reject { |m| m.role == :tool }
    {
      messages: kept,
      compaction: { removed_count: messages.size - kept.size }
    }
  end
end
```

---

## 9. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Pluggable array of compressors | Composition over inheritance; each compressor has one job |
| `ToolOutputPruner` is stateless | No LLM call; runs first to reduce cost before Summary |
| Rough token heuristic (4 chars/token) | Avoids embedding a tokenizer; exact count requires provider-specific code |
| `keep:` parameter | Prevents losing recent context which is most relevant to the current turn |
| Compaction metadata | Enables logging and debugging without coupling the compressor to any logger |
| Summary result replaces old messages | Stateful history is kept at minimum size; old messages are not re-summarised unless new messages push the count over the threshold again |
