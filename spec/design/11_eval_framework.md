# Phronomy — Eval Framework

## 1. Overview

The Eval framework provides a structured pipeline for measuring the quality of
agent (or any callable) outputs against a labelled dataset.

```
Dataset (EvalCase[])
      │
  Runner#run(dataset, callable)
      │
  Scorer (ExactMatch / Includes / LlmJudge / custom)
      │
  EvalResult[]
      │
  Metrics / Comparison
```

All components are plain Ruby objects; no database or external service is
required (unless using `LlmJudge`).

---

## 2. EvalCase

`lib/phronomy/eval/eval_case.rb`

Represents a single labelled test case.

```ruby
Phronomy::Eval::EvalCase.new(
  input:    "What is the capital of France?",
  expected: "Paris",
  metadata: { category: "geography" }   # optional
)
```

---

## 3. Dataset

`lib/phronomy/eval/dataset.rb`

An ordered, immutable collection of `EvalCase` objects.

```ruby
# From an array of hashes
dataset = Phronomy::Eval::Dataset.from_array([
  { input: "2+2",              expected: "4" },
  { input: "Capital of Japan", expected: "Tokyo" }
])

dataset.size   # => 2
dataset.each { |c| puts c.input }
```

---

## 4. Scorers

`lib/phronomy/eval/scorer/`

All scorers inherit from `Scorer::Base` and implement:

```ruby
def score(actual:, expected:, input: nil) → Float  # 0.0–1.0
```

### 4.1 ExactMatch

`Phronomy::Eval::Scorer::ExactMatch`

Returns `1.0` when `actual.strip == expected.strip` (case-insensitive by
default), `0.0` otherwise.

```ruby
Phronomy::Eval::Scorer::ExactMatch.new
Phronomy::Eval::Scorer::ExactMatch.new(case_sensitive: true)
```

### 4.2 IncludesScorer

`Phronomy::Eval::Scorer::IncludesScorer`

Returns `1.0` when `actual` includes `expected` (case-insensitive by default).

```ruby
Phronomy::Eval::Scorer::IncludesScorer.new
```

### 4.3 LlmJudge

`Phronomy::Eval::Scorer::LlmJudge`

Sends a structured prompt to an LLM and parses its numeric reply as the score.
Uses a configurable prompt template with three named placeholders:
`%<input>s`, `%<expected>s`, `%<actual>s`.

The LLM must reply with a single decimal number in `[0.0, 1.0]`. Extra text is
stripped; values are clamped. Returns `0.0` on parse error.

```ruby
judge = Phronomy::Eval::Scorer::LlmJudge.new(
  model:           "gpt-4o-mini",
  prompt_template: Phronomy::Eval::Scorer::LlmJudge::DEFAULT_PROMPT  # optional
)
```

**Default prompt:**
```
You are an impartial judge evaluating the quality of an AI assistant response.
Rate the response on a scale from 0.0 (completely wrong) to 1.0 (perfect).
Respond with ONLY a single decimal number.

Question: %<input>s
Expected answer: %<expected>s
Actual response: %<actual>s

Score:
```

---

## 5. Runner

`lib/phronomy/eval/runner.rb`

Runs a `Dataset` through a callable and collects `EvalResult` objects.

The callable must respond to `#call(input)` and may return:
- a plain `String` → treated as output; usage is `nil`
- a `Hash` with `:output` and optional `:usage` (TokenUsage)

Latency is measured per case using `Process::CLOCK_MONOTONIC` in milliseconds.

```ruby
runner  = Phronomy::Eval::Runner.new(scorer: Phronomy::Eval::Scorer::ExactMatch.new)
dataset = Phronomy::Eval::Dataset.from_array([{ input: "2+2", expected: "4" }])

# With a proc
results = runner.run(dataset, ->(input) { "4" })

# With a Phronomy agent
agent   = MyAgent.new
results = runner.run(dataset, ->(input) { agent.invoke(input) })
```

---

## 6. EvalResult

`lib/phronomy/eval/eval_result.rb`

Value object returned by `Runner#run`:

```ruby
result.eval_case   # the original EvalCase
result.actual      # String — actual output
result.score       # Float 0.0–1.0
result.usage       # Phronomy::TokenUsage or nil
result.latency_ms  # Integer — wall-clock time in ms
result.passed?     # score >= threshold (default: 1.0)
```

---

## 7. Metrics

`lib/phronomy/eval/metrics.rb`

Aggregates a collection of `EvalResult` objects:

```ruby
metrics = Phronomy::Eval::Metrics.new(results)
metrics.mean_score   # Float — average score
metrics.pass_rate    # Float — fraction with score >= threshold
metrics.mean_latency # Float — average latency in ms
metrics.total_input_tokens   # Integer
metrics.total_output_tokens  # Integer
```

---

## 8. Comparison

`lib/phronomy/eval/comparison.rb`

Compares two sets of results (e.g. baseline vs. new model):

```ruby
comparison = Phronomy::Eval::Comparison.new(baseline: results_a, candidate: results_b)
comparison.delta_mean_score  # Float — candidate minus baseline
comparison.improved_cases    # Array<EvalCase>
comparison.regressed_cases   # Array<EvalCase>
```

---

## 9. Full Example

```ruby
require "phronomy"

dataset = Phronomy::Eval::Dataset.from_array([
  { input: "Capital of France?", expected: "Paris" },
  { input: "Capital of Japan?",  expected: "Tokyo" }
])

agent  = MyGeographyAgent.new
runner = Phronomy::Eval::Runner.new(
  scorer: Phronomy::Eval::Scorer::LlmJudge.new(model: "gpt-4o-mini")
)

results = runner.run(dataset, ->(q) { agent.invoke(q) })
metrics = Phronomy::Eval::Metrics.new(results)

puts "Mean score: #{metrics.mean_score}"
puts "Pass rate:  #{metrics.pass_rate}"
```

---

## 10. Design Decisions

| Decision | Rationale |
|----------|-----------|
| Callable protocol (`#call`) | Works with procs, lambdas, and any object; no Agent coupling |
| Scorer returns Float not Boolean | Enables partial-credit scorers (LlmJudge) and threshold flexibility |
| Latency via `CLOCK_MONOTONIC` | Wall-clock latency; immune to system-clock adjustments |
| LlmJudge uses format string template | Fully replaceable prompt without subclassing |
| Comparison object | Facilitates A/B evaluation between two model or prompt variants |
