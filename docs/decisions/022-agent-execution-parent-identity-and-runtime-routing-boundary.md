# ADR 022: Agent Execution Parent Identity and Runtime Routing Boundary

**Status**: Accepted
**Date**: 2026-08-23
**Related**:
- [ADR-014](014-unified-persistence-durable-state.md)
- [ADR-021](021-generic-agent-invocation-identity-removal.md)
- [ADR-023](023-fsm-session-incarnation-identity-and-routing.md)
- [ADR-024](024-event-loop-single-writer-agent-runtime.md)

---

## Context

Phronomy has a canonical durable Agent execution identity, `execution_id`, but
Tool and approval paths still expose or carry the older
`agent_invocation_id`/`parent_agent_invocation_id` terminology.

Those older values mix two different concerns:

1. the logical parent Agent execution; and
2. the concrete Runtime FSMSession target used to deliver an event.

The two lifetimes differ. An Agent execution can survive a suspension while its
concrete FSMSession incarnation is rebuilt. A Runtime delivery target therefore
must not become the durable or application-facing parent identity.

`AgentInvocation` is the live FSM context of an `AgentExecution`; it is not a
separate logical/domain entity. `ToolInvocation` has its own Tool lifecycle
identity and provider Tool Call identity, but its logical parent is the owning
Agent execution.

## Decision

The canonical logical parent of Agent-owned Tool and approval work is
`execution_id`.

The current identity relationship is:

```text
AgentExecution
  execution_id

AgentInvocation
  execution_id          # parent reference, not an independent identity

ToolInvocation
  execution_id          # logical parent
  tool_invocation_id    # Tool lifecycle identity
  tool_call_id          # Provider-originated Tool Call identity

ToolApprovalRequest
  approval request id
  execution_id          # logical parent

ApprovalEvaluationRequest
  execution_id          # logical parent
  tool_invocation_id
  tool_call_id
```

Application-facing approval surfaces change as a clean break:

```text
ToolApprovalRequest#agent_invocation_id
  -> ToolApprovalRequest#execution_id

ToolApprovalRequest#to_h[:agent_invocation_id]
  -> ToolApprovalRequest#to_h[:execution_id]

ApprovalEvaluationRequest#agent_invocation_id
  -> ApprovalEvaluationRequest#execution_id
```

No deprecated alias is retained. Agent invocation configuration also rejects the
legacy `agent_invocation_id` key instead of allowing application code to control
a Runtime routing identifier.

## Runtime routing is separate

CG-03a does not redesign Runtime routing.

The implementation may temporarily retain private
`parent_agent_invocation_id`-named storage as the existing parent FSMSession
routing carrier until the Runtime foundation is reconciled. That temporary
carrier:

- is not the logical/domain parent;
- is not application-facing identity;
- is not a durable field;
- must not be renamed to `execution_id` and then used as an EventLoop target.

CG-03b, integrated with ACS-10/ACS-11, will give each concrete FSMSession its own
fresh ID and replace domain-object routing reuse with session-local Runtime
bindings. Rebuilt sessions receive rebuilt bindings. Stale completion must not be
applied to a new session merely because the logical execution is the same.

No long-lived `parent_fsm_session_id` field is introduced on `ToolInvocation`.

## Durable approval compatibility

Current approval suspension stores `ToolApprovalRequest#to_h` both as referenced
ContentStore audit content and in `AgentExecution#approval_request`.

New canonical approval request representations use `execution_id`.

Existing durable `AgentExecution` hashes may contain an embedded approval request
with `agent_invocation_id`. During `AgentExecution.from_h`, that legacy key is
discarded and the current logical parent is derived from the enclosing
`AgentExecution#execution_id`. The old `agent_invocation_id` value is not renamed
or reinterpreted as an execution ID.

Existing content-addressed approval audit bodies are not rewritten. Their bytes
are historical execution evidence and may retain the legacy field. New writes use
the current representation.

This is a targeted compatibility rule. It does not establish a general durable
schema/versioning policy, which remains separate persistence work.

## Staging

```text
CG-03a
  execution_id logical parent
  public approval clean break
  targeted embedded durable-read compatibility
  status: reconciled by the CG-03a change

CG-03b
  fresh FSMSession identity
  session-local Runtime routing binding
  stale-session completion rejection
  duplicate AgentInvocation/ToolInvocation session fields cleanup
  status: identity/routing slice implemented by ADR-023; result/live-state
          authority completed by ADR-024 / ACS-11
```

CG-03's Agent/Tool Runtime-foundation criteria are reconciled by the joint
ADR-023 / ADR-024 implementation: concrete-session routing is separated from
domain identity, and worker results return to EventLoop for current-state and
semantic-ID validation before live apply. Workflow admission ownership remains
separate ACS-13 work.

## CG-03b routing foundation implementation

The Runtime now binds Agent/Tool/Multi-Agent asynchronous completion through a
session-local `FSMSession::EventSink`. Rebuilt sessions receive fresh sinks and
IDs; old sinks are never rebound to a new `execution_id` incarnation.

`AgentInvocation` therefore has no independent `id`/`session_id`.
`ToolInvocation#id` remains the semantic Tool lifecycle identity and is no
longer reused as an FSMSession ID. Workflow uses a private FSMSession-owned
identity reservation only because its existing pre-load admission still uses the
future FSMSession ID; opaque Workflow admission ownership is explicitly ACS-13.

## Explicit non-goals

This decision does not in CG-03a:

- stop using `AgentInvocation#id` as an Agent FSMSession ID;
- stop using `ToolInvocation#id` as a Tool FSMSession ID;
- remove the temporary `parent_agent_invocation_id` Runtime routing carrier;
- remove `AgentInvocation#session_id` or `ToolInvocation#session_id`;
- add a long-lived `parent_fsm_session_id`;
- remove `AgentExecutionActivation`;
- implement EventLoop single-writer ownership;
- implement recovery, rehydration, fencing, or cross-process ownership;
- define general Persistence schema/version evolution.

## Consequences

### Positive

- Agent, Tool, and approval logical-parent vocabulary uses an existing
  purpose-specific domain identity.
- Application policy/notification code no longer receives a Runtime-oriented
  Agent invocation identity.
- Provider `tool_call_id`, Phronomy `tool_invocation_id`, approval request ID, and
  Agent `execution_id` remain distinct.
- Old embedded suspended-execution data remains readable without inventing a
  false identity mapping.
- The Runtime foundation can later change FSMSession incarnation/routing
  independently of durable and application-facing parent identity.

### Trade-offs

- This is a pre-1.0 breaking application API change.
- Applications that persisted `ToolApprovalRequest#to_h` must read the new
  `execution_id` key for newly produced requests.
- Historical content-addressed approval audit bodies are intentionally not
  rewritten and may still contain `agent_invocation_id`.
- The Agent/Tool portion of CG-03 is complete only when ADR-023 routing and
  ADR-024 EventLoop result authority are both present.
