> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Persistence, Durability, and Recovery

## 1. Durable boundary

`Phronomy::Persistence` is the single durable-state backend abstraction for
stateful Agents and durable Workflows.

```text
Persistence
├─ contents
├─ agents
├─ journals
├─ executions
└─ workflow_states
```

Persistence stores defined durable logical state. It is not serialization of the
currently running Runtime object graph.

Detailed custom-backend method/codec contracts belong in
[Persistence backends](../persistence-backends.md).

Normative durability vocabulary is
[ADR-018](../decisions/018-durability-guarantees-and-failure-model.md).

## 2. Durable versus Runtime-only state

Durable examples include AgentRoot, Journal records, AgentExecution records,
content/Manifest references, and durable Workflow snapshots.

Runtime-only examples include FSMSession objects/IDs, AgentInvocation objects,
Task instances/callbacks, EventLoop entries, Runtime admission entries, and
in-flight Provider/Tool operation objects.

Runtime/process loss removes Runtime-only objects but does not imply confirmed
durable state was lost.

## 3. Agent live ownership

After create/load, one live Agent instance owns current mutable logical Agent
state for that `agent_id` within one Runtime/process.

During execution, EventLoop is the single writer of Phronomy-managed live Agent
execution state.

```text
EventLoop authoritative snapshot
  -> OffloadPool command
  -> Persistence transaction
  -> immutable operation-specific result
  -> EventLoop authority validation
  -> live apply
```

See
[ADR-024](../decisions/024-event-loop-single-writer-agent-runtime.md).

## 4. Durable transitions and conflicts

Defined semantic durable transitions are atomic according to the Persistence
transaction contract and conforming backend.

Revision/watermark/CAS checks reject stale durable transitions with
`Persistence::ConflictError` rather than silently merging/reloading competing
state.

Conflict detection is not competing-execution exclusion and cannot undo an
external side effect already performed.

## 5. Agent and Workflow admission

Within one Runtime/process, Agent admission prevents prohibited competing
top-level execution for one logical Agent owner.

The canonical logical/durable Workflow identity is `workflow_instance_id`, which
is separate from one Runtime `fsm_session_id`.

Workflow same-process admission is acquired before durable hydration and retained
through the authoritative terminal/halted save barrier. The caller-facing Task
settles after that authoritative durable barrier.

See
[ADR-025](../decisions/025-process-local-agent-ownership-and-runtime-admission.md),
[ADR-020](../decisions/020-canonical-workflow-instance-identity.md), and
[ADR-026](../decisions/026-workflow-runtime-admission-and-durable-terminal-barrier.md).

## 6. Cross-process guarantee

Cross-process competing-execution exclusion is conditional.

A multi-process deployment must provide stable routing/partitioning by logical
identity or another coordination mechanism that establishes exclusive authority.
Persistence CAS/revision checks alone detect stale commits; they do not prevent
duplicate semantic execution from starting.

Phronomy does not claim arbitrary external exactly-once side effects.

## 7. Durable codec

Durable backend exchange uses immutable
`Phronomy::Persistence::DurableRecord` values with:

```text
record_type
format_version
payload
```

`format_version` is a durable representation version, not Agent definition
version, Workflow identity, or Runtime incarnation identity.

Payloads follow the canonical durable value/codec contract. A backend may use its
own physical storage representation but must return an equivalent logical
DurableRecord.

## 8. Recovery model

Recovery reconstructs logical state from confirmed durable evidence; it does not
restore the old Runtime object graph.

The shared Recovery vocabulary classifies unfinished work as:

```text
resumable
reconcilable
resolution_required
```

Where outcome is uncertain, Phronomy does not infer "not performed" merely from
connection/process failure and does not blindly re-dispatch an external
operation.

Application resolution, when required, records one of:

```text
succeeded
failed
not_performed
```

before dependent continuation may proceed.

Agent Recovery is integrated into supported `Agent.load` lifecycle semantics.

## 9. Manifest authority during Recovery

A finalized historical `LLMInputManifest` is reused for the Provider input it
represents. Recovery does not rerun historical ContextPolicy code to reconstruct
that finalized input.

## 10. External-effect boundary

External Provider/Tool/Application effects are outside the ordinary Phronomy
Persistence transaction boundary (`X0` in ADR-018).

Therefore:

- durable-transition atomicity is not external-effect atomicity;
- semantic IDs alone do not prevent duplicate external effects;
- retry eligibility depends on outcome certainty plus operation-specific
  idempotency/reconciliation contracts; and
- arbitrary exactly-once external side-effect execution is not an unconditional
  Phronomy guarantee.

## 11. Reference backend details are not architecture

InMemory implementation mechanisms do not become requirements for external
backends unless the Backend SPI states the corresponding semantic property.
