# ADR-023: FSMSession Incarnation Identity and Runtime Routing Foundation

**Status**: Accepted
**Date**: 2026-08-23
**Related**:
- [ADR-010](010-cooperative-first-concurrency.md)
- [ADR-014](014-unified-persistence-durable-state.md)
- [ADR-020](020-canonical-workflow-instance-identity.md)
- [ADR-022](022-agent-execution-parent-identity-and-runtime-routing-boundary.md)

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

### 4. Provider completion is routed before it updates Activation result state

Provider completion callbacks no longer call
`AgentExecutionActivation#record_llm_result` before Runtime routing. They post an
immutable `LLMOperationResult` through the current session sink, and the existing
AgentInvocation EventLoop handler records that result only if the concrete
session still owns the event.

This is a targeted stale-session safety correction. It does not make
`AgentExecutionActivation` the final architecture and does not complete ACS-11.

### 5. Runtime incarnation identity is not durable state

`fsm_session_id`, identity reservations, event sinks, callbacks, Tasks, and
other process-local Runtime values are not persisted as logical recovery state.
Recovery creates fresh Runtime objects from confirmed durable semantic state.

## Relationship to ACS-11 and ACS-13

This decision is the ACS-10 identity/routing foundation and the implementation
half of CG-03b. It intentionally does **not** claim the whole Runtime foundation
wave is complete.

ACS-11 remains immediately next. Current Offload paths still contain broader
worker-side live-state mutation through `AgentExecutionActivation` and
`ExecutionCoordinator`; those paths must become operation-specific immutable
Command/Snapshot/Result flows whose results are applied on EventLoop after
current-state and semantic-authority checks. CG-03 remains open until that joint
foundation closes the remaining stale-result-authority gap.

ACS-13 separately owns Workflow's opaque admission owner handle and the durable
terminal-save barrier. This ADR does not pull those Workflow lifecycle changes
forward. The current `owner_fsm_session_id` admission representation remains an
explicit transitional mismatch until ACS-13.

## Explicit non-goals

This decision does not implement:

- ACS-11 EventLoop single-writer / `AgentExecutionActivation` removal;
- ACS-13 Workflow opaque admission owner or durable-save-before-terminal barrier;
- restart-safe HITL/Workflow rehydration;
- same-process Agent admission redesign;
- cross-process ownership, leases, or fencing;
- general Persistence schema/version evolution.

## Consequences

### Positive

- Agent/Tool/Multi-Agent domain IDs are no longer EventLoop routing IDs.
- Rebuilt sessions receive fresh session-local routing sinks.
- Old-session provider completion is not applied to a newer session merely
  because the logical `execution_id` is unchanged.
- Workflow preserves pre-load admission ordering without retaining arbitrary
  caller-supplied FSMSession IDs.
- ACS-13 admission-owner redesign remains cleanly separated.

### Trade-offs

- Workflow temporarily uses a private FSMSession identity reservation because
  its current admission owner is still the future FSMSession ID.
- The larger EventLoop single-writer mismatch remains until ACS-11 lands.
