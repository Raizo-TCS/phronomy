# Phronomy — Knowledge Sources, Loaders & Splitters

## 1. Overview

The Knowledge subsystem provides structured knowledge injection into agent
context windows. It is composed of three cooperating layers:

```
Document files
      │
  Loader (Markdown / CSV / PlainText)
      │
  Splitter (FixedSize / Recursive)
      │
  VectorStore (InMemory / pgvector / Redis)
      │
  KnowledgeSource (Static / RAG / Entity)
      │
  Context::Assembler  →  <context> XML tag
      │
  Agent LLM prompt
```

All three KnowledgeSource adapters produce `Array<Hash>` chunks of the form:

```ruby
{ content: "...", type: :policy, source: "refund_policy.md" }
```

`type` is a semantic tag rendered as a context XML attribute.
`source` is optional; when present it is rendered in the XML tag and
exposed to the LLM for grounded citation.

---

## 2. KnowledgeSource::Base

`lib/phronomy/knowledge_source/base.rb`

Abstract base class. Subclasses must implement:

| Method | Signature | Notes |
|--------|-----------|-------|
| `fetch` | `(query: nil) → Array<Hash>` | Returns knowledge chunks |
| `static?` | `→ Boolean` | `true` if content never changes per invocation |

---

## 3. KnowledgeSource::StaticKnowledge

`lib/phronomy/knowledge_source/static_knowledge.rb`

Injects a fixed text document regardless of the query. Ideal for policy files,
FAQs, product specifications, or any document that does not need retrieval.

### Constructor

```ruby
Phronomy::KnowledgeSource::StaticKnowledge.new(
  text,          # String — the knowledge content
  type:   :static,  # Symbol — semantic tag (default :static)
  source: nil       # String — source label for citations
)
```

### Behaviour

- `fetch(query: nil)` → always returns the same single chunk
- `static?` → `true`; the agent caches the assembled context and skips
  reassembly unless the instruction fingerprint changes

### Example

```ruby
ks = Phronomy::KnowledgeSource::StaticKnowledge.new(
  File.read("refund_policy.md"),
  type:   :policy,
  source: "refund_policy.md"
)

class SupportAgent < Phronomy::Agent::Base
  static_knowledge ks
end
```

---

## 4. KnowledgeSource::RAGKnowledge

`lib/phronomy/knowledge_source/rag_knowledge.rb`

Retrieval-Augmented Generation: embeds the query and fetches the k nearest
documents from a VectorStore.

### Constructor

```ruby
Phronomy::KnowledgeSource::RAGKnowledge.new(
  store:      store,       # Phronomy::VectorStore::Base
  embeddings: embeddings,  # Phronomy::Embeddings::Base
  k:          5,           # Integer — number of chunks to retrieve
  type:       :rag,        # Symbol — semantic tag
  source:     nil          # String — default source label; falls back to doc metadata
)
```

### Behaviour

- `fetch(query:)` → embeds query → searches store → returns k chunks
- Returns `[]` when query is nil or blank
- `source` per chunk is `@source || doc[:metadata][:source]`
- `static?` → `false` (result changes per query)

### Full RAG Pipeline Example

```ruby
# 1. Load documents
loader   = Phronomy::Loader::MarkdownLoader.new
docs     = loader.load("guide.md")

# 2. Split into chunks
splitter = Phronomy::Splitter::RecursiveSplitter.new(chunk_size: 500, chunk_overlap: 50)
chunks   = docs.flat_map { |doc| splitter.split(doc) }

# 3. Embed and index
store      = Phronomy::VectorStore::InMemory.new
embeddings = Phronomy::Embeddings::RubyLLMEmbeddings.new(model: "text-embedding-3-small")
chunks.each_with_index do |chunk, i|
  store.add(
    id:        i.to_s,
    embedding: embeddings.embed(chunk[:text]),
    metadata:  chunk[:metadata].merge(content: chunk[:text])
  )
end

# 4. Attach to agent
ks = Phronomy::KnowledgeSource::RAGKnowledge.new(
  store:      store,
  embeddings: embeddings,
  k:          3,
  source:     "guide.md"
)

agent.invoke("How do I reset my password?", config: { knowledge_sources: [ks] })
```

---

## 5. KnowledgeSource::EntityKnowledge

`lib/phronomy/knowledge_source/entity_knowledge.rb`

Stateful; accumulates named-entity facts extracted from user messages using
regex heuristics (no LLM call required). Useful for personalised assistants
that need to remember "my name is Alice" across turns.

### Supported Patterns

| Pattern | Key | Example |
|---------|-----|---------|
| `my name is X` | `:name` | "my name is Alice" |
| `I am X` | `:identity` | "I am a student" |
| `I'm a/an X` | `:occupation` | "I'm a software engineer" |
| `I work at/for X` | `:workplace` | "I work at Acme" |
| `I live in X` | `:location` | "I live in Tokyo" |
| `I'm from X` | `:location` | "I'm from Osaka" |
| `I like/love X` | `:preference` | "I love Ruby" |

### Usage

```ruby
ks = Phronomy::KnowledgeSource::EntityKnowledge.new

# Call after each message save
ks.update(messages: manager.load_messages(thread_id: "t1"))

agent.invoke("What is my name?", config: { knowledge_sources: [ks] })
```

---

## 6. Loaders

`lib/phronomy/loader/`

Loaders read source files and return `Array<Hash>` documents:
`[{ text: "...", metadata: { source: "file.md", ... } }]`

### MarkdownLoader

```ruby
loader = Phronomy::Loader::MarkdownLoader.new(split_on_headings: true)
docs   = loader.load("guide.md")
# Each H1–H6 section becomes a separate document with metadata[:section]
```

Options:
- `split_on_headings: true` (default) — splits on H1–H6 boundaries
- `split_on_headings: false` — returns the entire file as one document

### PlainTextLoader

```ruby
loader = Phronomy::Loader::PlainTextLoader.new
docs   = loader.load("notes.txt")
# Returns single document; metadata: { source: "notes.txt" }
```

### CsvLoader

```ruby
loader = Phronomy::Loader::CsvLoader.new(text_column: "body", metadata_columns: [:title, :url])
docs   = loader.load("articles.csv")
# Each row becomes one document; listed columns become metadata
```

---

## 7. Splitters

`lib/phronomy/splitter/`

Splitters accept a `Hash` document `{ text:, metadata: }` and return
`Array<Hash>` chunks with `metadata[:chunk]` index appended.

### FixedSizeSplitter

Splits on character count with overlap. Fast and simple.

```ruby
splitter = Phronomy::Splitter::FixedSizeSplitter.new(
  chunk_size:    1000,  # max characters per chunk
  chunk_overlap: 200    # overlap characters between adjacent chunks
)
chunks = splitter.split(doc)
```

### RecursiveSplitter

Tries separators in priority order (`"\n\n"`, `"\n"`, `". "`, `" "`, `""`),
recursing to the next separator when a piece is still larger than `chunk_size`.

```ruby
splitter = Phronomy::Splitter::RecursiveSplitter.new(
  chunk_size:    500,
  chunk_overlap: 50,
  separators:    ["\n\n", "\n", ". ", " ", ""]  # default
)
chunks = splitter.split(doc)
```

---

## 8. Context Assembly

`KnowledgeSource#fetch` chunks are assembled into the agent's system prompt by
`Context::Assembler#add_knowledge`. Each chunk is wrapped in a `<context>` XML
tag:

```xml
<context type="policy" source="refund_policy.md" trusted="true">
  Customers may request a full refund within 30 days...
</context>
```

Attributes:
- `type` — from `chunk[:type]`
- `source` — from `chunk[:source]` (omitted when nil)
- `trusted` — from the `trusted:` keyword arg (default false)

---

## 9. Static vs Dynamic Knowledge

| | StaticKnowledge | RAGKnowledge | EntityKnowledge |
|-|-----------------|--------------|-----------------|
| `static?` | `true` | `false` | `false` |
| Query dependency | None | Required | None |
| LLM call | None | For embedding | None |
| State | Stateless | Stateless | Stateful (accumulates) |
| Registration | `static_knowledge` DSL or `knowledge_sources:` config | `knowledge_sources:` config | `knowledge_sources:` config |

Static knowledge is cached by `Agent::Base` using an instruction fingerprint;
the assembled context is reused across invocations without re-fetching.
