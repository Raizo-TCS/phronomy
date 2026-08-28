> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Agent Context, Identity, and Ownership

## 1. System boundary

A stateful Agent separates canonical durable facts, one live Runtime owner, and
the logical input finalized for each Provider call.

```text
Application
    |
live Agent instance  -- agent_id --> one Runtime-local mutable owner
    |
    +-- AgentRoot / Journal view
    |
    +-- AgentExecution -- execution_id
            |
            +-- FSMSession incarnation -- fsm_session_id
            |
            +-- Provider Call -- llm_call_id
            |
            +-- ToolInvocation -- tool_invocation_id / tool_call_id
```

`agent_id` identifies the logical Agent. `execution_id` identifies one logical
Agent execution. `fsm_session_id` identifies one Runtime execution incarnation.
Provider and Tool semantic IDs identify their own operations. These identities
are intentionally distinct.

Phronomy does not restore a generic Agent `thread_id`, `session_id`,
`correlation_id`, or `agent_invocation_id` identity. Application observability
may use `InvocationContext#task_id` / `#parent_task_id`, but those values are not
Agent, Workflow, Tool, or Runtime domain identities.

Relevant decisions:
[ADR-021](../decisions/021-generic-agent-invocation-identity-removal.md),
[ADR-022](../decisions/022-agent-execution-parent-identity-and-runtime-routing-boundary.md),
and [ADR-023](../decisions/023-fsm-session-incarnation-identity-and-routing.md).

## 2. Canonical history and one-call input

The Agent Journal is append-only canonical execution history. It is not the
Provider message buffer.

```text
Journal / registered Knowledge / current-call material
        |
        v
ContextPolicyInput
  instruction / knowledge / tools / conversation
        |
        v
ContextPolicy
        |
        v
ContextPlan
        |
        v
ContextAssembler
        |
        v
LLMInputManifest
        |
        v
RubyLLMMaterializer
        |
        v
Provider
```

The finalized `LLMInputManifest` is the logical authority for one Provider Call.
The Journal remains the canonical history authority. Context selection never
rewrites old Journal facts.

See [Context Management](context-management.md) and
[ADR-012](../decisions/012-canonical-execution-log-and-context-policy.md).

## 3. Live mutable ownership

Within one Runtime/process, one mutable live Agent instance owns one `agent_id`.
Loading or creating a second mutable live instance for the same `agent_id` is
rejected.

During active execution, EventLoop is the single writer of Phronomy-managed live
Agent execution state. Blocking Persistence work and other synchronous work that
must not run on EventLoop are submitted to OffloadPool. Worker results return as
immutable operation-specific results and are applied only after EventLoop checks
that the current execution/session/semantic-operation authority still matches.

Persistence conflict detection protects durable state from stale writes. It is
not a substitute for Runtime ownership.

See
[ADR-024](../decisions/024-event-loop-single-writer-agent-runtime.md) and
[ADR-025](../decisions/025-process-local-agent-ownership-and-runtime-admission.md).

## 4. Same-process and cross-process responsibility

Same-process competing top-level Agent execution is rejected by Runtime
admission. Cross-process competing-execution exclusion is **conditional**, not an
unconditional Phronomy guarantee.

A multi-process deployment must arrange stable routing/partitioning by logical
identity or use an external coordination mechanism that establishes exclusive
authority. Optimistic Persistence CAS/revision checks detect stale durable
transitions; they do not themselves provide distributed exclusion.

Phronomy does not currently add a distributed lease/fencing coordinator, live
Agent migration protocol, or automatic takeover subsystem merely because
Persistence is durable.

See
[ADR-018](../decisions/018-durability-guarantees-and-failure-model.md).

## 5. Suspension, recovery, and process loss

A live approval suspension retains the logical Agent execution slot. A later
approval resumes the same logical `execution_id` with a new Runtime
FSMSession incarnation as needed.

After Runtime/process loss, process-local objects are gone. `Agent.load` uses
confirmed durable state to classify unfinished work as:

```text
resumable
reconcilable
resolution_required
```

Recovery does not restore the old Ruby object graph or old Task callbacks. It
reconstructs current logical state from durable evidence and continues only
when authority and outcome certainty permit it.

A finalized historical Manifest is reused for the Provider input it represents;
Recovery does not rerun the historical Context Policy merely to reconstruct that
Manifest.

See [Persistence](persistence.md) for the durability/recovery boundary.

## 6. Multi-Agent responsibility

A semantic Handoff changes which live Agent is responsible for continuing the
interaction. It does not merge Source and Target canonical state.

Transferred Handoff Context is immutable request-scoped material. The Target
Context Policy may select it for a Target LLM Call, but Handoff does not
automatically append it to Target Journal or persistent Knowledge.

Active Target responsibility persists across later Runner turns only within the
same Runtime/main-Agent coordination lifetime. It is not durably rehydrated
after Runtime/process reset.

See [Multi-Agent Handoff](multi-agent-handoff.md).

## 7. Removed models

The following are not current Agent Context authorities:

- mutable RubyLLM message history as canonical Agent state;
- `Memory::ConversationManager`;
- `LlmContextWindow::Assembler`;
- `ContextVersionCache`;
- a Static/Entity/RAG Knowledge source hierarchy;
- a generic Agent conversation/thread/session identity;
- cross-Agent Journal sharing as Handoff semantics.

See [Removed Agent Context Architecture](removed/agent-context.md) for the
negative guidance retained from the retired designs.
