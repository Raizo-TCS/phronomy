> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Tracing and Observability

## 1. Scope

Phronomy provides a public custom-tracer SPI plus a deliberately small set of
Framework-owned automatic logical-operation spans.

Tracing is observability. It is not execution authority, domain identity,
Persistence durability, or a distributed tracing coordinator.

## 2. Public tracer extension SPI

`Phronomy::Tracing::Base` defines the extension boundary:

```ruby
start_span(name, input: nil, **metadata)
finish_span(span, output: nil, usage: nil, error: nil)
trace(name, input: nil, **metadata) { |span| ... }
```

Configured tracer instances may receive calls concurrently from independent
Phronomy operations. Custom tracers must protect any mutable shared state they
own and must not assume OS-thread, EventLoop, or OffloadPool affinity.

Phronomy ships no-op, Langfuse, and OpenTelemetry tracer implementations. Adapter
behavior must be distinguished from Framework-wide guarantees.

## 3. Automatic logical-operation coverage

Framework automatic tracing is intentionally limited to:

```text
agent.execution
workflow.execution
llm.call
tool.execute
multi_agent.turn
```

Internal steps such as ContextPolicy execution, Context assembly, Persistence
transactions, EventLoop dispatch, OffloadPool work, and FSM transitions are not
part of the standard automatic span topology.

Applications may add custom tracing independently.

## 4. Sync/async parity

Automatic span semantics attach to the logical operation, not to the public
blocking facade method.

```text
invoke / invoke_async
stream / stream_async
        |
        v
same logical Agent operation
        |
        v
agent.execution
```

The same principle applies to Workflow run/resume operations.

## 5. Span lifetimes

### `agent.execution`

One active Agent run/resume segment.

The span starts after `execution_id` has been established and the active segment
is about to run. It ends when that segment's caller-facing TaskResult settles.

Suspension closes the active span. Later approval/recovery continuation creates a
new `agent.execution` span correlated by the same logical `execution_id`.

Phronomy does not keep one span open for the full durable lifetime of an Agent
execution.

### `workflow.execution`

One Workflow run/resume operation, ending with that operation's TaskResult settlement.
The durable identity is `workflow_instance_id`.

### `llm.call`

One Provider Call after `llm_call_id` assignment. Streaming chunks do not create
separate spans.

### `tool.execute`

One authorized physical Tool execution. Approval waiting time is outside this
span.

### `multi_agent.turn`

One coarse `MultiAgent::HandoffRunner` user turn. Handoff does not create a mandatory
long-lived span type.

## 6. Correlation and identity

Portable Phronomy correlation uses existing purpose-specific semantic metadata,
for example:

```text
agent_id
execution_id
llm_call_id
tool_invocation_id
tool_call_id
workflow_instance_id
task_id / parent_task_id
```

Phronomy does not add a second tracing identity hierarchy or restore generic
Agent `thread_id`/`session_id`.

`InvocationContext#tracer_span` is not part of the current API.

## 7. Parent/child semantics

Phronomy does not define a custom `TraceContext`, `SpanContext`, `parent_span`
API, EventLoop span registry, or durable span state.

A backend such as OpenTelemetry may preserve natural lexical nesting where its
own context is active. That adapter behavior does not establish a Phronomy-wide
guarantee that automatic spans form one backend-native parent/child tree across
TaskResult/EventLoop/Offload/Runtime boundaries.

## 8. `trace_pii`

For Framework-owned automatic spans, `trace_pii: false` prevents traced payload
content and sensitive exception detail from being exposed to the tracer.

The automatic boundary redacts/omits:

- Agent/LLM input and output payloads;
- Tool argument/result payloads;
- transferred textual payload where recorded;
- exception message/backtrace; and
- selected sensitive caller metadata fields.

Structural operation metadata, purpose-specific semantic IDs, status/error
class/category, and token usage may remain observable.

Automatic instrumentation does not copy arbitrary Application metadata
wholesale.

## 9. Automatic tracing failure policy

Framework-owned automatic tracing is best-effort. A tracer failure during
automatic `start_span`/`finish_span` is warning-only where possible and does not
change the logical Agent/Workflow/LLM/Tool/Multi-Agent result.

This guarantee is specific to Framework automatic instrumentation. It does not
redefine the behavior of Application code that directly calls the public
`Tracing::Base#trace` template method.

Automatic span completion that must leave the EventLoop uses the existing
Execution contract's bounded `automatic_tracing` named pool: one worker and
100 waiting slots, owned by the default Runtime. Its admission capacity is
separate from the default business-work pool. This is an internal allocation,
not an additional application scheduling API.

For example, a Tool can finish before its completion callback is registered.
The callback then runs immediately on the EventLoop. Recording that Tool's
completion must not consume the only default-pool slot needed to prepare the
next provider call. Conversely, a full default pool does not refuse a tracing
completion while the tracing pool still has capacity.

Submission never waits for queue space. If the tracing pool is full or the
Runtime rejects new work during shutdown, the automatic boundary reports a
warning and does not retry or run the tracer inline on the EventLoop. Accepted
trace work remains owned by Runtime shutdown; a worker that exceeds the shutdown
budget can leave cleanup incomplete. A completed business TaskResult does not
prove that its trace has been exported, and trace delivery is not durable.

This separates deferred completion admission, not all tracing execution cost.
`start_span` and completion from a blocking-allowed caller keep their existing
synchronous behavior. Named pools do not isolate process CPU or memory, and
configured tracers remain responsible for their own I/O timeouts. The tracer
SPI, redaction, logical span boundaries and public invocation results are
unchanged.

## 10. Observed token counts

Tracing receives a plain `Hash[Symbol, Integer?]` in `usage:`. Supported keys are:

```text
input
output
cached
cache_creation
```

A backend may export the subset its telemetry schema supports. Missing/unknown
counts remain nil and zero remains a measurement. Tracing does not accept or
interpret a domain-specific usage object. The LLM domain retains ownership of
its immutable usage value and aggregation rules; its caller projects the value
with `to_h` before sending it to Tracing. Agent owns that projection for both
`llm.call` and `agent.execution`. Arbitrary Workflow/Tool results are not inspected
for a `usage` field by Tracing.

For manual tracing, change `[result, usage]` to `[result, usage&.to_h]` when the
second value is a domain object. Custom exporters read `usage[:input]` and
`usage[:output]` instead of calling methods on the domain object. No compatibility
conversion inside Tracing is retained: it would preserve the dependency being
removed. The `usage:` keyword, span lifecycle and external telemetry field names
are unchanged.

The internal automatic task observer accepts an owner-supplied projection. A
failed projection is diagnostic-only: it records no usage and does not change
the operation result or prevent the span from finishing. Tracing has no static
dependency on LLMAdapter. This does not assign LLM retry policy to Tracing or to
the common LLM contract.

## 11. Backend notes

### NullTracer

NullTracer is the default no-op tracer. It avoids external telemetry work but no
literal "zero runtime cost" guarantee is made.

### Langfuse

Langfuse ingestion failure does not fail the Framework automatic logical
operation. Failures are reported as warnings when possible.

### OpenTelemetry

The caller/application configures the OpenTelemetry SDK/exporter. Phronomy does
not configure an exporter or propagator on the application's behalf.
