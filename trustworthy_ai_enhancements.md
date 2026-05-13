# Trustworthy AI Enhancements

Specification for features that address the NIST AI Risk Management Framework (AI RMF 1.0)
trustworthiness characteristics, as applied to the phronomy gem.

Reference: NIST AI 100-1 — https://doi.org/10.6028/NIST.AI.100-1
Japanese translation: https://aisi.go.jp/assets/pdf/NIST_AI_RMF_jp_20240806.pdf

---

## Responsibility Model

Three layers share responsibility for trustworthy AI:

```
┌─────────────────────────────────────────┐
│  Application  Domain logic / UX          │
├─────────────────────────────────────────┤
│  phronomy     Control flow / observation / boundary enforcement │
├─────────────────────────────────────────┤
│  LLM          Probabilistic reasoning / generation              │
└─────────────────────────────────────────┘
```

Key principle: **the LLM is untrusted**. phronomy acts as the deterministic control
layer that validates, constrains, and observes LLM behaviour. Characteristics that
cannot be delegated to the LLM must be enforced by phronomy or the application layer.

---

## Trustworthiness Characteristics — Status and Plan

### 3.1 Valid and Reliable

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Base reasoning capability | Model-dependent |
| **phronomy** | Eval infrastructure, output type validation | ✅ `Eval::Runner`, `Eval::Dataset`, `Eval::Metrics` — see `lib/phronomy/eval/` |
| **phronomy** | Drift / accuracy monitoring hooks | ❌ Not implemented — **planned** |
| Application | Test-case design, accuracy thresholds | Application responsibility |

**Planned work:**
- None in this iteration. `Eval` infrastructure is sufficient for current needs.

---

### 3.2 Safe

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Basic harmful-content avoidance (RLHF) | Model-dependent, not guaranteed |
| **phronomy** | Intervention points, iteration limits, approval gates | ✅ `wait_state`/`send_event`, `requires_approval`, `max_iterations` — see `lib/phronomy/workflow.rb`, `lib/phronomy/agent/base.rb` |
| **phronomy** | Built-in guardrails (PII, prompt injection) | ❌ Not implemented — **planned (Feature A)** |
| Application | Concrete guardrail logic, approval workflows | Application responsibility |

---

### 3.3 Secure and Resilient

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Partial prompt-injection resistance | Model-dependent, partial |
| **phronomy** | State persistence across process restarts | ✅ `StateStore::ActiveRecord` — see `lib/phronomy/state_store/` |
| **phronomy** | Encrypted state store adapter interface | ❌ Not implemented — **planned (Feature C)** |
| Application | Authentication / authorisation / infrastructure encryption | Application / infrastructure responsibility |

---

### 3.4 Accountable and Transparent

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Token usage reporting | ✅ `TokenUsage` — see `lib/phronomy/token_usage.rb` |
| **phronomy** | Tracing / span recording | ✅ `Tracing::LangfuseTracer`, `OpenTelemetryTracer` — see `lib/phronomy/tracing/` |
| **phronomy** | Caller identity propagation to tracers | ❌ Not implemented — **planned (Feature B)** |
| Application | User-facing AI disclosure, business audit requirements | Application responsibility |

---

### 3.5 Explainable and Interpretable

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Chain-of-thought generation | Prompt-dependent |
| **phronomy** | Processing step recording via Graph and Tracing | ✅ Partial — `Workflow`/`WorkflowRunner`, `Tracing` |
| Application | Explanation UI, CoT prompt design | Application responsibility |

**Planned work:** None in this iteration.

---

### 3.6 Privacy-Enhanced

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Training data handling | Provider responsibility |
| **phronomy** | Memory compression (data minimisation) | ✅ `Memory::Compression` — see `lib/phronomy/memory/compression/` |
| **phronomy** | Built-in PII detection guardrail | ❌ Not implemented — **planned (Feature A)** |
| **phronomy** | TTL and explicit purge API on ConversationManager | ❌ Not implemented — **planned (Feature D)** |
| Application | Privacy policy, user consent management | Application responsibility |

---

### 3.7 Fair — with Harmful Bias Managed

| Layer | Responsibility | Status |
|---|---|---|
| LLM | Bias reduction via RLHF | Provider responsibility |
| **phronomy** | Eval infrastructure for custom metrics | ✅ `Eval::Metrics` — extensible |
| Application | Fairness test-set design, threshold definition | Application responsibility |

**Planned work:** None in this iteration. The existing `Eval::Metrics` extension
point is sufficient; fairness metrics are domain-specific and belong to the
application layer.

---

## Planned Features (This Branch)

### Feature A — `Phronomy::Guardrail::Builtin` module

**Addresses:** 3.2 Safe, 3.6 Privacy-Enhanced

**Motivation:**
Prompt injection and PII leakage are the two most common, high-severity risks for
any LLM application. They require deterministic, regex/heuristic-based detection
that the LLM cannot reliably provide. phronomy should ship sensible defaults so
that applications do not have to re-implement these from scratch.

**Design:**
- New module: `Phronomy::Guardrail::Builtin`
- Two concrete classes, both under `lib/phronomy/guardrail/builtin/`:
  - `PromptInjectionDetector < InputGuardrail`
  - `PIIPatternDetector < InputGuardrail`
- Existing base classes (`InputGuardrail`, `OutputGuardrail`) are unchanged — see
  `lib/phronomy/guardrail/input_guardrail.rb` and `output_guardrail.rb`.

**`PromptInjectionDetector`:**
- Detects common prompt-injection patterns in input strings:
  - "ignore previous instructions", "disregard all prior", "system prompt:" prefixes,
    jailbreak keywords, role-switch attempts.
- Pattern list is configurable via constructor argument `additional_patterns: []`.
- Raises `GuardrailError` with message `"Potential prompt injection detected"`.

**`PIIPatternDetector`:**
- Detects common Japanese and international PII patterns:
  - Japanese My Number (12-digit number): `/\b\d{4}[- ]?\d{4}[- ]?\d{4}\b/`
  - Credit card numbers: `/\b(?:\d{4}[- ]?){3}\d{4}\b/`
  - Email addresses: standard RFC 5322 simplified pattern
  - Phone numbers (JP): `/\b0\d{1,4}[- ]?\d{1,4}[- ]?\d{4}\b/`
- Each pattern category is independently togglable via constructor:
  `PIIPatternDetector.new(detect: [:my_number, :credit_card, :email, :phone])`
- Default: all four categories active.
- Raises `GuardrailError` with message `"PII detected in input: <category>"`.

**Usage example:**
```ruby
agent = MyAgent.new
agent.add_input_guardrail(Phronomy::Guardrail::Builtin::PromptInjectionDetector.new)
agent.add_input_guardrail(Phronomy::Guardrail::Builtin::PIIPatternDetector.new(detect: [:my_number, :credit_card]))
```

**Files to create:**
- `lib/phronomy/guardrail/builtin/prompt_injection_detector.rb`
- `lib/phronomy/guardrail/builtin/pii_pattern_detector.rb`
- `lib/phronomy/guardrail/builtin.rb` (requires both, defines module)
- Update `lib/phronomy/guardrail.rb` to require `builtin`

**Tests:**
- Unit: `spec/phronomy/guardrail/builtin/prompt_injection_detector_spec.rb`
- Unit: `spec/phronomy/guardrail/builtin/pii_pattern_detector_spec.rb`
- Integration: extend `spec/integration/tool_guardrail_spec.rb` with builtin guardrail factors

---

### Feature B — Caller identity propagation in `config:`

**Addresses:** 3.4 Accountable and Transparent

**Motivation:**
`Tracing` already records what happened (spans, token usage). What is missing is
**who** triggered the action. Without a caller identity, audit logs cannot be
attributed to users or sessions, which is a requirement for accountability under
NIST AI RMF 3.4.

**Design:**
- `Agent::Base#invoke` and `WorkflowRunner#invoke` already accept `config: {}` — see
  `lib/phronomy/agent/base.rb` and `lib/phronomy/graph/workflow_runner.rb`.
- Add two new optional keys to `config:`:
  - `user_id:` (String | nil) — caller identity
  - `session_id:` (String | nil) — session / request identity
- Both are extracted in `invoke_once` / `call` and forwarded to
  `Tracing::Base#start_span` as span attributes.
- `Tracing::Base#start_span` already accepts `**attributes` — no signature change needed.
- `LangfuseTracer` and `OpenTelemetryTracer` will automatically forward them as
  metadata/attributes respectively.

**Usage example:**
```ruby
agent.invoke("What is the weather?", config: {
  thread_id: "conv-123",
  user_id:   "user-42",
  session_id: "sess-abc"
})
```

**Files to modify:**
- `lib/phronomy/agent/base.rb` — extract `user_id` and `session_id` from config, pass to tracer
- `lib/phronomy/graph/compiled_graph.rb` — same for graph invocations

**Tests:**
- Unit: extend `spec/phronomy/agent_spec.rb` with `user_id`/`session_id` forwarding assertions
- Unit: extend `spec/phronomy/tracing/langfuse_tracer_spec.rb` with attribute forwarding

---

### Feature C — `StateStore` encryption adapter interface

**Addresses:** 3.3 Secure and Resilient

**Motivation:**
`StateStore::ActiveRecord` persists conversation state as plain-text JSON. In
regulated environments (healthcare, finance, government) this violates data-at-rest
requirements. phronomy should define a standard interface so that an encryption
adapter can be layered transparently without modifying `StateStore::ActiveRecord`.

**Design:**
- New abstract class: `Phronomy::StateStore::Encryptor::Base`
  - `encrypt(plaintext) → ciphertext` (abstract)
  - `decrypt(ciphertext) → plaintext` (abstract)
- New concrete class: `Phronomy::StateStore::Encryptor::ActiveSupport`
  - Delegates to `ActiveSupport::MessageEncryptor` when available.
  - Constructor: `ActiveSupport.new(secret_key_base:, cipher: "aes-256-gcm")`
- `StateStore::ActiveRecord` accepts an optional `encryptor:` constructor argument:
  - When present, `serialize_state` output is passed through `encryptor.encrypt`
    before writing to the DB, and `encryptor.decrypt` before `deserialize_state`.
  - When absent, behaviour is unchanged (backwards compatible).

**Usage example:**
```ruby
encryptor = Phronomy::StateStore::Encryptor::ActiveSupport.new(
  secret_key_base: ENV.fetch("SECRET_KEY_BASE")
)
store = Phronomy::StateStore::ActiveRecord.new(
  model_class: PhronomyStateRecord,
  encryptor: encryptor
)
```

**Files to create:**
- `lib/phronomy/state_store/encryptor/base.rb`
- `lib/phronomy/state_store/encryptor/active_support.rb`
- `lib/phronomy/state_store/encryptor.rb`

**Files to modify:**
- `lib/phronomy/state_store/active_record.rb` — accept `encryptor:`, apply in save/load
- `lib/phronomy/state_store.rb` — require `encryptor`

**Tests:**
- Unit: `spec/phronomy/state_store/encryptor/base_spec.rb`
- Unit: `spec/phronomy/state_store/encryptor/active_support_spec.rb`
- Unit: extend `spec/phronomy/state_store_spec.rb` with encrypted save/load round-trip

---

### Feature D — TTL and `purge` API on `ConversationManager`

**Addresses:** 3.6 Privacy-Enhanced

**Motivation:**
Users have a right to be forgotten. `ConversationManager` currently has no way to
delete stored messages for a given thread, nor does it enforce data retention limits.

**Design:**
- `ConversationManager#purge(thread_id:)` — deletes all stored messages for the
  thread from both the storage backend and the retrieval index.
- Optional `ttl:` constructor argument (Integer seconds | nil):
  - When set, messages older than `ttl` seconds are filtered out on `load_messages`.
  - Storage backends that support native TTL (e.g. Redis) should be informed via
    a `Storage::Base#purge_older_than(thread_id:, older_than:)` hook.
  - Default: `nil` (no expiry — current behaviour unchanged).
- `Storage::ActiveRecord` gains a `purge_older_than` implementation using
  `where("created_at < ?", Time.now - ttl).destroy_all`.

**Usage example:**
```ruby
memory = Phronomy::Memory::ConversationManager.new(
  storage: Phronomy::Memory::Storage::ActiveRecord.new(model_class: PhronomyMessageRecord),
  ttl: 60 * 60 * 24 * 30  # 30 days
)
# Later:
memory.purge(thread_id: "conv-123")
```

**Files to modify:**
- `lib/phronomy/memory/conversation_manager.rb` — add `purge`, accept `ttl:`
- `lib/phronomy/memory/storage/base.rb` — add `purge(thread_id:)` abstract method, `purge_older_than` hook
- `lib/phronomy/memory/storage/active_record.rb` — implement both
- `lib/phronomy/memory/storage/in_memory.rb` — implement both

**Tests:**
- Unit: extend `spec/phronomy/memory_spec.rb` with `purge` and TTL filtering tests
- Unit: extend `spec/phronomy/active_record/message_spec.rb` with `purge_older_than`

---

## Implementation Order

| Step | Feature | Rationale |
|---|---|---|
| 1 | Feature A — BuiltinGuardrails | Self-contained, no dependencies, highest safety impact |
| 2 | Feature B — Caller identity | Small change, high accountability value |
| 3 | Feature C — Encryptor I/F | More complex, depends on no other feature |
| 4 | Feature D — TTL / purge | Touches storage layer, do last to avoid churn |

Each feature follows the same workflow:
1. Implement source files
2. Run StandardRB on new files
3. Run unit tests: `bundle exec rspec <spec_file>`
4. Run full unit suite: `bundle exec rspec --format progress`
5. Run integration suite: `bundle exec rspec --tag integration --format progress`
6. Present diff for commit approval

---

## Out of Scope (This Branch)

- Fairness metrics / demographic parity (`Eval::Metrics` extension) — domain-specific,
  belongs to application layer
- Kill switch / forced shutdown — infrastructure concern
- Differential privacy — academic/research topic, not yet practical for gem scope
- Authentication / authorisation — application / infrastructure concern
