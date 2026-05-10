# Phronomy — Tracing & Observability

## 1. Overview

Phronomy provides pluggable span-based tracing. Every LLM call made by a Chain
or Agent is wrapped in a span via the `#trace` helper on the active tracer.

The tracer is configured globally and shared across all components:

```ruby
Phronomy.configure do |c|
  c.tracer = Phronomy::Tracing::LangfuseTracer.new(...)
end
```

When no tracer is configured, `NullTracer` is used (all spans are discarded).

---

## 2. Class Hierarchy

```
Phronomy::Tracing::Base          (abstract)
├── Phronomy::Tracing::NullTracer
├── Phronomy::Tracing::LangfuseTracer
└── Phronomy::Tracing::OpenTelemetryTracer
```

---

## 3. Tracing::Base

`lib/phronomy/tracing/base.rb`

The abstract base class. Subclasses implement two methods:

| Method | Signature | Purpose |
|--------|-----------|---------|
| `start_span` | `(name, input: nil, **meta) → span` | Begin a trace span |
| `finish_span` | `(span, output: nil, usage: nil, error: nil)` | End a trace span |

The `#trace` template method in `Base` composes these two methods:

```ruby
def trace(name, input: nil, **meta)
  span = start_span(name, input: input, **meta)
  result, usage = yield span
  finish_span(span, output: result, usage: usage)
  result
rescue => e
  finish_span(span, error: e)
  raise
end
```

Callers yield `[result, usage]` where `usage` is a `Phronomy::TokenUsage`
instance or `nil`.

---

## 4. NullTracer

`lib/phronomy/tracing/null_tracer.rb`

No-op tracer used by default. `start_span` returns `nil`; `finish_span` is a
no-op. Zero runtime cost.

---

## 5. LangfuseTracer

`lib/phronomy/tracing/langfuse_tracer.rb`

Sends spans to Langfuse via the batch ingestion REST API
(`POST /api/public/ingestion`). Uses only Ruby stdlib (`net/http`, `json`,
`base64`) — no external gem required.

Ingestion errors are **silently swallowed** so a Langfuse outage never
breaks the application.

### Configuration

```ruby
Phronomy.configure do |c|
  c.tracer = Phronomy::Tracing::LangfuseTracer.new(
    public_key: ENV.fetch("LANGFUSE_PUBLIC_KEY"),
    secret_key: ENV.fetch("LANGFUSE_SECRET_KEY"),
    host:       ENV.fetch("LANGFUSE_HOST", "https://cloud.langfuse.com")
  )
end
```

Supports self-hosted Langfuse by overriding `host:`.

### Span Payload

Each span is serialised as a `span-create` Langfuse event:

| Field | Source |
|-------|--------|
| `id` | `SecureRandom.uuid` |
| `traceId` | `SecureRandom.uuid` (per span) |
| `name` | `name` argument |
| `startTime` | captured at `start_span` |
| `endTime` | captured at `finish_span` |
| `input` | `input:` keyword argument |
| `output` | `output:` keyword argument |
| `usage.input` | `usage.input` (token count) |
| `usage.output` | `usage.output` (token count) |
| `level` | `"ERROR"` when `error:` is set |
| `statusMessage` | `error.message` when error |

---

## 6. OpenTelemetryTracer

`lib/phronomy/tracing/open_telemetry_tracer.rb`

Integrates with the OpenTelemetry Ruby SDK. Requires `opentelemetry-api` (or
`opentelemetry-sdk` for testing). The caller must configure the OTel SDK and
exporter before using this tracer — phronomy does not set up exporters.

### Configuration

```ruby
require "opentelemetry-sdk"
OpenTelemetry::SDK.configure { |c| c.use_all }

Phronomy.configure do |c|
  c.tracer = Phronomy::Tracing::OpenTelemetryTracer.new(
    tracer_name: "phronomy"   # default
  )
end
```

### Span Attributes

| OTel Attribute | Source |
|----------------|--------|
| `phronomy.input` | `input:` argument |
| `phronomy.<key>` | any extra `**attributes` |
| `phronomy.output` | `output:` argument |
| `llm.usage.input_tokens` | `usage.input` |
| `llm.usage.output_tokens` | `usage.output` |
| `llm.usage.total_tokens` | `usage.input + usage.output` |

Errors are recorded via `span.record_exception` and
`span.status = OpenTelemetry::Trace::Status.error(...)`.

---

## 7. Custom Tracer

Implement `Tracing::Base` and override `start_span` / `finish_span`:

```ruby
class MyTracer < Phronomy::Tracing::Base
  def start_span(name, input: nil, **meta)
    { name: name, started_at: Time.now }
  end

  def finish_span(span, output: nil, usage: nil, error: nil)
    duration = Time.now - span[:started_at]
    MyMonitoring.record(span[:name], duration: duration, error: error&.message)
  end
end

Phronomy.configure { |c| c.tracer = MyTracer.new }
```

---

## 8. TokenUsage

`lib/phronomy/token_usage.rb`

A simple value object passed from RubyLLM to the tracer:

```ruby
Phronomy::TokenUsage.new(input: 120, output: 85)
# usage.input   => 120
# usage.output  => 85
```

---

## 9. Design Decisions

| Decision | Rationale |
|----------|-----------|
| No gem dependency for Langfuse adapter | Avoids adding `faraday` or `httparty` to the gemspec |
| Errors silently swallowed in LangfuseTracer | Observability must never break production |
| NullTracer default | Zero config required; tracing is opt-in |
| `#trace` template method in Base | Guarantees `finish_span` is always called even on error |
| Per-span traceId in Langfuse | Simplest approach; a production tracer could propagate a parent trace |
