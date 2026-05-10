# Phronomy — TrustPipeline

## 1. Overview

`Phronomy::TrustPipeline` orchestrates three complementary mechanisms to
produce trustworthy LLM outputs:

| # | Mechanism | What it does |
|---|-----------|-------------|
| 1 | **Citation Tracking** | Prompts the DraftAgent to list the knowledge sources it relied on; citations are extracted and attached to the result |
| 2 | **Self-Review Loop** | A dedicated ReviewAgent evaluates each draft and provides feedback; rejected drafts are retried with that feedback embedded in the next prompt |
| 3 | **Confidence Gate** | A combined score (`min(self_score, review_score)`) is compared against a threshold; the result exposes `trusted?` accordingly |

---

## 2. Public API

### 2.1 Constructor

```ruby
pipeline = Phronomy::TrustPipeline.new(
  draft_agent:          PolicyDraftAgent,  # Class < Phronomy::Agent::Base
  review_agent:         PolicyReviewAgent, # Class < Phronomy::Agent::Base
  confidence_threshold: 0.7,              # Float 0.0–1.0 (default: 0.7)
  max_iterations:       3                 # Integer (default: 3)
)
```

### 2.2 Invoke

```ruby
result = pipeline.invoke("What is the refund policy?", config: {})
```

`config` is forwarded to each agent invocation (e.g. `thread_id`).

### 2.3 Result

`Phronomy::TrustPipeline::Result` is an immutable `Struct`:

```ruby
result.output       # String — final answer
result.trusted?     # Boolean — confidence >= threshold
result.confidence   # Float 0.0–1.0 — min(self_score, review_score)
result.citations    # Array<Hash> — [{ source: "...", excerpt: "..." }, ...]
result.iterations   # Integer — number of draft-review cycles
result.review_notes # Array<String> — reviewer feedback per cycle
```

---

## 3. Internal Graph

`TrustPipeline` uses `Phronomy::Graph::StateGraph` internally with a private
`PipelineState` class that includes `Phronomy::Graph::State`.

### State fields

| Field | Type | Description |
|-------|------|-------------|
| `input` | `:replace` | Original user question |
| `draft` | `:replace` | Parsed draft hash from DraftAgent |
| `self_score` | `:replace` | DraftAgent's self-reported confidence |
| `review_score` | `:replace` | ReviewAgent's quality score |
| `citations` | `:replace` | Extracted `[{source:, excerpt:}]` |
| `review_notes` | `:append` | Reviewer feedback per cycle (accumulated) |
| `iteration` | `:replace` | Current cycle count |
| `approved` | `:replace` | Whether the ReviewAgent approved the draft |
| `output` | `:replace` | Final answer string |

### Graph topology

```
:draft ──→ :review ──→ (conditional)
                  ├── approved OR iterations exhausted ──→ :finalize ──→ FINISH
                  └── rejected AND iterations remain   ──→ :draft (loop)
```

---

## 4. Prompt Design

### DraftAgent prompt

The DraftAgent is called via `agent_class.new.invoke(prompt)` where `prompt`
is constructed dynamically:

**First attempt:**
```
Answer the following question. Respond with ONLY valid JSON:
{
  "answer": "...",
  "confidence": 0.0–1.0,
  "citations": [{ "source": "...", "excerpt": "..." }]
}

Question: <user question>
```

**Retry (with reviewer feedback):**
```
Previous answer was rejected. Reviewer feedback: <feedback>

Answer the following question again. Respond with ONLY valid JSON: ...

Question: <user question>
```

### ReviewAgent prompt

```
Review the following answer and respond with ONLY valid JSON:
{
  "approved": true|false,
  "score": 0.0–1.0,
  "feedback": "..."
}

Question: <question>
Answer: <draft answer>
```

---

## 5. JSON Parsing & Fallbacks

Both prompts use `Phronomy::OutputParser::JsonParser` to parse responses.
When the LLM returns malformed JSON, safe fallbacks are applied:

| Agent | Fallback behaviour |
|-------|--------------------|
| DraftAgent parse failure | `answer = raw_text`, `confidence = 0.0`, `citations = []` |
| ReviewAgent parse failure | `approved = false`, `score = 0.0`, `feedback = "unparseable review"` |

This ensures the pipeline never raises on unparseable output; it simply
continues with degraded confidence.

---

## 6. Confidence Calculation

```
confidence = min(self_score, review_score)
trusted    = confidence >= confidence_threshold
```

The `min` function ensures both the agent and the reviewer must be confident.
A high self-score with a low reviewer score (or vice versa) is not trusted.

After `max_iterations` cycles:
- If still not approved, `trusted = false` and the best available draft is
  returned as output.

---

## 7. Citation Tracking Integration

KnowledgeSource adapters carry a `source:` label:

```ruby
StaticKnowledge.new(File.read("policy.md"), type: :policy, source: "policy.md")
```

`Context::Assembler` emits this label in the XML context tag:

```xml
<context type="policy" source="policy.md" trusted="true">...</context>
```

The LLM can then reference the `source` label in its JSON `citations` array,
providing grounded, traceable answers.

---

## 8. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Uses `StateGraph` internally | Consistent with phronomy's own graph runtime; loop logic is naturally expressed as a conditional edge |
| `Result` is a Struct | Immutable value object; all fields accessible without mutation |
| `min(self, review)` for confidence | Both parties must agree; prevents an agent from inflating its own score |
| JSON output format | Structured parsing; robust to model variation |
| Fallback on parse failure | Pipeline never raises; caller can check `trusted?` |
| `max_iterations` default = 3 | Balances quality improvement against cost; configurable per use case |
| `draft_agent` / `review_agent` accept classes | Instantiates a fresh agent per pipeline invocation; avoids state leakage between calls |
