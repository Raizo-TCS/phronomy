# ADR 021: Generic Agent Invocation Identity Removal

**Status**: Accepted  
**Date**: 2026-08-23  
**Partially supersedes**: [ADR-014](014-unified-persistence-durable-state.md) for `InvocationContext` generic session/correlation semantics and Agent-side generic invocation identity

---

## Context

Phronomy historically exposed `thread_id` and `session_id` as generic
invocation metadata. Agent `thread_id` was copied through execution metadata,
Journal `correlation_id`, Manifest model configuration, and Multi-Agent child
dispatch, but it did not identify Agent ownership, durable Agent state, resume,
or Runtime event routing.

`InvocationContext#session_id` likewise did not correspond to a Phronomy-owned
session domain object or lifecycle. Renaming either value to another generic
identity such as `correlation_id`, `conversation_id`, or
`application_session_id` would preserve the ambiguity instead of resolving it.

Phronomy already has purpose-specific semantic identifiers such as
`execution_id`, `llm_call_id`, `tool_invocation_id`, `tool_call_id`,
`approval_request_id`, `workflow_instance_id`, and Runtime-local
`FSMSession#id`. Tracing task identifiers are a separate observability concern.

## Decision

Generic Agent invocation identity is removed as a clean break.

The public contract does not include:

```text
InvocationContext#thread_id
InvocationContext#session_id

Agent#invoke(thread_id:)
Agent#invoke_async(thread_id:)
Agent#stream(thread_id:)
Agent#stream_async(thread_id:)
```

The same generic value is not propagated through Multi-Agent child dispatch,
AgentExecution metadata, approval context, or finalized LLM model
configuration.

No replacement generic identity field is introduced.

`InvocationContext#task_id` and `#parent_task_id` remain tracing /
observability identifiers. They are not promoted to Agent, Workflow, Tool, or
Runtime domain identity.

Agent configuration rejects legacy `thread_id` and `session_id` keys at
execution/resume boundaries rather than retaining an untyped compatibility
backdoor.

## Durable Journal migration

The architecture decision also removes generic `JournalRecord#correlation_id`
from the new canonical representation. Existing durable Journal data is not
rewritten merely to remove that field.

Implementation is staged:

```text
CG-02a
  public / non-durable generic identity removal
  status: reconciled by the CG-02a change

CG-02b
  remove correlation_id from the new canonical Journal representation
  accept/ignore the legacy key during backward read
  no eager durable rewrite
  status: reconciled by the CG-02b change
```

`JournalRecord.from_h` intentionally reconstructs only current canonical
attributes. A legacy durable Hash may therefore contain `correlation_id`; the
removed key is accepted and ignored rather than restored as domain identity.
This compatibility rule avoids an eager rewrite of existing Journal data and
does not define a general unknown-field or schema-versioning policy.

## Explicit non-goals

This decision does not:

- change FSMSession identity ownership;
- rename the shared Runtime `set_graph_metadata(thread_id:)` bridge;
- remove Runtime-only `AgentInvocation#session_id`;
- migrate `agent_invocation_id` parent references to `execution_id`
  (subsequently decided by [ADR-022](022-agent-execution-parent-identity-and-runtime-routing-boundary.md));
- redesign Tool / Approval Runtime routing;
- remove `AgentExecutionActivation`;
- implement EventLoop single-writer ownership;
- implement recovery, fencing, or cross-process ownership.

Those concerns belong to the subsequent Runtime identity / ownership change
sets and compatibility gates.

## Consequences

### Positive

- Agent and Workflow no longer overload the same generic `thread_id` term.
- Arbitrary application session/correlation concepts are not elevated into the
  Phronomy core identity catalog.
- Tracing task correlation remains available without being confused with
  lifecycle ownership.
- Multi-Agent child execution no longer inherits an undefined generic identity.
- The public contract and architecture vocabulary become purpose-specific.

### Trade-offs

- This is a pre-1.0 breaking API change.
- Applications that used Agent `thread_id` / `InvocationContext#session_id`
  must move correlation into application tracing/observability metadata or use
  the actual purpose-specific domain identifier.
- Legacy durable Journal data retains targeted backward-read compatibility;
  broader codec/schema versioning policy remains a separate persistence decision.
