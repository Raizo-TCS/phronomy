# ADR-046: Agent Responsibility Layout and Shared Records

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-21
**Refines**: [038-responsibility-based-source-layout](038-responsibility-based-source-layout.md)
and [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md)

## Problem

Agent's direct directory contained 41 files with unrelated responsibilities.
Recovery also obtained the ordinary execution coordinator solely to invoke its
private record encoder and content writer. RecoverySupport mixed recovery
vocabulary, durable reads, and construction of live invocations.

Moving files alone does not resolve that coupling. Moving transaction decisions
into a shared encoder would instead give it too many responsibilities.

## Decision

Apply and verify the changes in two stages: source placement first, then shared
record generation and restoration responsibilities.

### Source placement

Collapse the following directories with Zeitwerk, preserving existing Agent
constant names and the application entry point `require "phronomy"`:

| Directory | Responsibility |
| --- | --- |
| `agent/lifecycle/` | Agent identity, ownership and fallback construction contract |
| `agent/execution/` | Invocation, phase transitions, admission and execution coordination |
| `agent/tool_execution/` | Tool invocation, authorization, approval and interception |
| `agent/context_assembly/` | Candidate selection, budgeting and Provider context materialization |
| `agent/journal/` | Canonical execution records and their projection |
| `agent/handoff/` | Agent-owned Handoff contracts, state and execution coordination |
| `agent/recovery/` | Durable recovery classification, resolution and live restoration |

The three files below `recovery_coordinator/` move with their owning class into
`recovery/recovery_coordinator/`. That directory retains its real nested Ruby
namespace; it is not independently collapsed. Existing API, composition,
context contracts, capabilities, concerns and persistence directories retain
their responsibilities. `base.rb`, `async_event_api.rb` and `shared_state.rb`
remain directly under Agent. SharedState's multi-Agent orchestration is a
separate future ownership decision, not evidence of generic shared data.

Update relative requires and source-reading regression guards. Do not provide
old-path forwarding shims: arbitrary implementation-file requires are not a
public partial-loading API. Existing constant identities, method signatures,
ancestry, lifecycle extension installation and stored class names are preserved.

### Shared record generation

`Agent::RuntimeRecordEncoder` under `execution/` receives execution facts, the
Agent identity, root generation, context eligibility and an existing transaction.
It writes content and returns JournalRecord and LLMCallRecord values. Ordinary
execution and recovery resolution both call it directly. It has no Agent live
object, coordinator, Runtime lookup, transaction opener, journal append, execution
save, commit/reconciliation decision or task settlement responsibility.
The encoder belongs to execution because it interprets Tool interception and
Provider settlement; the journal value/projection directory must not depend on
Tool execution solely to classify those facts.

Keep call sequence numbering, interception-as-success, abandoned call recording,
Tool message duplicate detection, context eligibility, content formats and
canonical-value failure messages. The caller still owns the transaction and
F1 outcome reconciliation. Encoding is not a pure function because it writes
content using that caller-owned transaction.

### Saved context and live restoration

`Agent::SavedContextReader` under `context_assembly/` reads persisted manifests,
materializes projections, and obtains saved Provider output/usage. Execution
preparation reconciliation, Handoff and Recovery consume this common reader.
Reading occurs in the same worker/caller preparation phase as before, outside
EventLoop state application.

`Agent::InvocationRestorer` under `recovery/` constructs live Chat, AgentInvocation
and ToolInvocation state from already-materialized facts. Suspended and resolved
continuations share the same invocation/chat construction sequence. Tool status,
approval facts, listener, invocation mode, coordination configuration, cancellation
and message order are preserved. It does not perform persistence reads or decide
which continuation to execute. RecoverySupport retains recovery metadata and
subject vocabulary rather than forwarding to the extracted helpers.

## Compatibility and limits

No public API or extension SPI is changed, and the existing API snapshot is not
regenerated. These three helpers are internal (`@api private`). Removed methods
on the internal RecoverySupport module and ExecutionCoordinator are not public
application contracts. No persistence schema, durability level, exactly-once
claim, cancellation rule, external effect replay rule or ownership rule changes.

ExecutionCoordinator still owns several operations and remains large. Recovery
still calls its private continuation/terminal entry points; this decision only
removes the record-generation and content-writing coupling. Moving directories
reveals previously internal cycles; counts across different grouping schemes are
not directly comparable. No claim of eliminating all Agent cycles is made.

## Verification

Verify the placement-only checkpoint before extracting helpers. Run ordinary
and recovery tests, F1 response-loss and I/O-boundary checks, restart/output-filter
coverage, full and integration suites, API byte comparison, RBS, annotations,
style and examples. Compare the complete encoded records and captured content
against the baseline under fixed timestamps and IDs, including success, structured
output, failure, interception, abandoned calls, duplicate Tool messages and
context eligibility. Verify gem packaging includes every moved/new source and
loads without the old implementation paths.
