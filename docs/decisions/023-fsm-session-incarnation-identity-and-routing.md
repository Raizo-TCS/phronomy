# ADR-023: FSMSession Incarnation Identity and Runtime Routing Foundation

**Status**: Accepted
**Date**: 2026-08-23
**Related**:
- [ADR-010](010-cooperative-first-concurrency.md)
- [ADR-014](014-unified-persistence-durable-state.md)
- [ADR-020](020-canonical-workflow-instance-identity.md)
- [ADR-022](022-agent-execution-parent-identity-and-runtime-routing-boundary.md)
- [ADR-024](024-event-loop-single-writer-agent-runtime.md)

---

## Context

Phronomy's EventLoop routes events to concrete `FSMSession` instances. Before
this decision, Agent, Tool, and Multi-Agent context objects generated IDs that
were injected into `FSMSession`, and callbacks later reused those object IDs as
EventLoop routing targets. Workflow likewise pre-generated a Runtime ID because
its current same-process admission is acquired before durable hydration.

This mixes domain/context identity with the identity of one concrete Runtime FSM
incarnation and makes suspend/resume stale-result safety difficult to reason
about.

## Decision

### 1. Concrete FSMSession identity is allocated by FSMSession infrastructure

A normal concrete `FSMSession` generates and owns a fresh `FSMSession#id` when
constructed. Agent, Tool, and Multi-Agent domain/context IDs are not injected as
that identity.

Across Runtime object/event boundaries the value is named `fsm_session_id`.
Terminal management payloads use `fsm_session_id` rather than generic
`session_id`.

Workflow is a narrow transitional case. Its current admission must be acquired
before durable state load, while the concrete FSMSession is constructed only
after hydration. Until ACS-13 separates Workflow admission ownership from
FSMSession routing identity, Workflow obtains a single-use identity reservation
from `FSMSession.reserve_identity`; the concrete FSMSession later claims exactly
that Runtime-owned reservation. Arbitrary raw `id:` injection is removed.

This reservation is Runtime-only and is not a Workflow/domain identity.

### 2. Async routing uses session-local event sinks

A concrete FSMSession has a Runtime-only event sink bound exactly once to its
`fsm_session_id`. Async work captures the sink belonging to the session that
started it. A rebuilt session receives a different sink and ID.

An old sink is never rebound or retargeted. If its session has terminated,
`EventLoop#post_to_session` rejects the old target rather than translating it to
a new session of the same logical execution.

This foundation is applied to Agent LLM completion/stream chunks, Tool
authorization/execution, Tool-to-parent notifications, callback-failure
notification, and Multi-Agent fan-out completion/timeout/cancellation.

### 3. Agent and Tool live/domain objects do not duplicate routing identity

`AgentInvocation` is a live FSM context belonging to `execution_id`; it has no
independent `id` and no duplicate Runtime `session_id`.

`ToolInvocation#id` remains the semantic `tool_invocation_id`. It is not an
FSMSession ID. ToolInvocation stores neither a duplicate session ID nor a
long-lived parent FSMSession ID. Parent routing is supplied as a session-local
sink when a Tool FSMSession is constructed.

No `parent_fsm_session_id`, generic generation token, or replacement generic
correlation identity is introduced.

### 4. Provider completion is routed before live result application

Provider completion callbacks post an immutable `LLMOperationResult` through the
session-local sink. The result carries the Provider Call's semantic `llm_call_id`.
The AgentInvocation EventLoop handler applies it only when the concrete session
still owns the event and the `llm_call_id` still matches the current Provider
Call.

ADR-024 completes this result-authority rule by making EventLoop the single
writer of Phronomy-managed live Agent execution state and by removing the former
Activation shared-mutable state model.

### 5. Runtime incarnation identity is not durable state

`fsm_session_id`, identity reservations, event sinks, callbacks, Tasks, and
other process-local Runtime values are not persisted as logical recovery state.
Recovery creates fresh Runtime objects from confirmed durable semantic state.

## Relationship to ACS-11 and ACS-13

This decision is the ACS-10 identity/routing foundation and the implementation
half of CG-03b. ADR-024/ACS-11 builds directly on it: Offload work now returns
operation-specific results and EventLoop validates/applies those results against
current Runtime state and purpose-specific semantic identity.

Together, ADR-023 and ADR-024 close the Agent/Tool result-routing and live-state
authority portion of CG-03 without introducing another generic identity.

ACS-13 separately owns Workflow's opaque admission owner handle and the durable
terminal-save barrier. This ADR does not pull those Workflow lifecycle changes
forward. The current `owner_fsm_session_id` admission representation remains an
explicit transitional mismatch until ACS-13.

## Explicit non-goals

This decision does not implement:

- ACS-13 Workflow opaque admission owner or durable-save-before-terminal barrier;
- restart-safe HITL/Workflow rehydration;
- same-process Agent admission redesign;
- cross-process ownership, leases, or fencing;
- general Persistence schema/version evolution.

Those items remain governed by their own later change sets. EventLoop single-
writer Agent ownership itself is defined by ADR-024 rather than duplicated here.

## Consequences

### Positive

- Agent/Tool/Multi-Agent domain IDs are no longer EventLoop routing IDs.
- Rebuilt sessions receive fresh session-local routing sinks.
- Old-session Provider completion is not applied to a newer session merely
  because the logical `execution_id` is unchanged.
- Provider results are additionally protected by current semantic `llm_call_id`.
- Workflow preserves pre-load admission ordering without retaining arbitrary
  caller-supplied FSMSession IDs.
- ACS-13 admission-owner redesign remains cleanly separated.

### Trade-offs

- Workflow temporarily uses a private FSMSession identity reservation because
  its current admission owner is still the future FSMSession ID.
- Runtime result application now requires explicit state/semantic-ID validation
  rather than relying on a shared mutable continuation container.
