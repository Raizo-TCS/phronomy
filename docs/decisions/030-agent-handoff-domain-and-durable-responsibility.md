# ADR-030: Agent Handoff Domain and Durable Responsibility

## Status

Accepted. V2 revision 2, 2026-09-06.

User approval covers the V2 boundary and the five recovery-contract clarifications.
Acceptance is design authority; it is not a claim of repository integration or test success.

## Date

2026-09-06

## Partially supersedes

`016-semantic-multi-agent-handoff` for:

- namespace/domain placement of Handoff;
- Runtime-local-only active responsibility;
- allowance for independent Source/Target Persistence domains in the durable
  Handoff path; and
- the public Handoff Runner namespace.

ADR-016 remains the historical rationale and remains authoritative for the
Source-to-Target semantic transfer model, HandoffPolicy category semantics,
Context dependency grouping, immutable transferred Context, Target ContextPolicy
ownership, and provenance rules except where this ADR explicitly changes them.

## Context

ADR-016 intentionally made active Handoff responsibility Runtime-local. Process
reset therefore restarted responsibility at the main Agent.

That behavior is insufficient for a framework-owned Handoff abstraction once the
Source execution has durably committed `:handed_off`: process loss must not force
Source semantic work to run again merely to rediscover the Target.

This is a framework semantic-routing concern, not an Application callback concern.
ADR-029 therefore does not make Handoff durability depend on restart-spanning
notification delivery.

## Decision

### 1. Handoff moves to the Agent domain

Public types move as a clean break:

```text
Phronomy::MultiAgent::Handoff
  -> Phronomy::Agent::Handoff

Phronomy::MultiAgent::HandoffPolicy
  -> Phronomy::Agent::HandoffPolicy

Phronomy::MultiAgent::Runner
  -> Phronomy::Agent::HandoffRunner
```

Handoff-specific private types move under the Agent Handoff implementation
boundary.

No compatibility alias is required by this ADR.

### 2. `main_agent.agent_id` is the durable routing anchor

No generic coordination/thread/session identity is introduced.

```text
main_agent.agent_id
  = durable Handoff routing anchor
```

One durable HandoffState is keyed by that identity.

### 3. Persistence adds `handoff_states`

The durable state contains semantic routing facts only:

```text
main_agent_id
handoff_revision
active_agent_id
active_handoff_context_ref
phase
pending_source_execution_id
pending_target_execution_id
created_at
updated_at
metadata
```

It never stores Agent instances, Agent classes, Procs, HandoffPolicy objects,
Tasks, FSMSessions or EventLoop routing state.

### 4. One durable Handoff graph uses one Persistence domain

The main/source/target Agents and HandoffState must use the same
`Phronomy::Persistence` transaction domain.

A graph requiring a distributed transaction across independent Persistence
domains is rejected before semantic work.

### 5. Source terminalization and responsibility transfer are one semantic transaction

When a Source chooses a valid Handoff, Phronomy:

1. resolves the current finalized Source Manifest;
2. applies HandoffPolicy projection;
3. materializes immutable HandoffContext;
4. reserves the exact Target `execution_id`;
5. commits Source `:handed_off` and HandoffState transfer atomically.

The transaction records at least:

```text
Source AgentExecution -> :handed_off
Source AgentRoot terminal/idle revision
Source Journal audit facts
HandoffContext content reference
HandoffState.active_agent_id -> Target
HandoffState.active_handoff_context_ref -> transferred Context
HandoffState.phase -> target_pending
HandoffState.pending_source_execution_id -> Source execution_id
HandoffState.pending_target_execution_id -> reserved Target execution_id
```

There is no terminal callback-delivery descriptor in this transaction.

### 6. Target execution identity is reserved before Target semantic work

Recovery uses the exact reserved Target `execution_id`:

```text
authoritatively absent after a successful read
  -> establish that exact reserved execution only after admission is confirmed

nonterminal
  -> recover that exact execution

terminal
  -> consume its durable outcome; never create a replacement execution
```

The execution ID is semantic Agent identity, not Runtime FSMSession identity.

### 7. Active responsibility survives later turns and process loss

When a Handoff turn ends normally at Target B, `active_agent_id` remains B.

The next HandoffRunner turn starts at B.

After process reset, compatible HandoffRunner wiring loads the same HandoffState
and again starts/resumes from B rather than reverting to the original main Agent.

### 8. Multi-hop updates the same HandoffState

A -> B -> C updates the original main-Agent-anchored HandoffState.

No nested generic coordination IDs are created.

### 9. Runtime graph/Policy wiring is Application code

HandoffRunner requires the current Application-supplied Handoff graph and Policies
to reconstruct Runtime behavior.

Those Ruby objects are never persisted.

If required wiring is absent or incompatible, recovery fails closed instead of:

- reverting to main Agent;
- inventing a graph;
- blindly replaying Source work.

### 10. HandoffContext is durably materializable but not adopted automatically

The canonical immutable HandoffContext value is stored in ContentStore and
referenced by HandoffState/execution metadata.

Transferred material remains request-scoped Target Context unless Target
execution creates its own canonical Journal/Knowledge facts.

### 11. Local Application events are Runtime-only

A Source may emit a same-process `:handoff` event.

That event is not durable routing authority and is not redelivered after restart.

Handoff coordination correctness depends only on durable semantic routing facts.

### 12. Recovery evidence, compatibility and cancellation

Apply [RC-01 through RC-05](../design/durable-semantic-coordination/RECOVERY_CONTRACT_CLARIFICATIONS.md).
Read failures/unknown commit outcomes must not be treated as Target absence.
Readback reconciles the same reserved execution and transfer facts; admission
races use existing atomic admission/CAS, never a replacement Target ID.

Before continuation, check main/active/Target identities, current required graph
connections, declared definition compatibility and the same Persistence instance.
Absent an existing explicit migration/compatibility contract, definition id/version
must match. Current wiring never reprojects committed HandoffContext. Proc/code
hashing and automatic semantic code-compatibility detection are not introduced.

Result reads follow the specified run's recorded Target, not an unrelated later
turn's latest active result. Continuation wiring is not required merely to read
stored status/canonical results.

After transfer commit the Source remains handed_off. Observation loss or cancel
must not roll active responsibility back to main. An explicit cancellation of the
current turn is routed to that turn's exact reserved Target under existing Agent
cancellation rules; it does not cancel unrelated/later executions. Preserve the
facts needed to reconcile cancellation/admission races and process loss.

## Required invariants

1. Handoff is an Agent-domain capability.
2. `main_agent.agent_id` is the durable routing anchor.
3. Active responsibility survives process loss.
4. Source `:handed_off` and durable responsibility transfer cannot diverge.
5. Target semantic work never starts without a recoverable reserved execution ID.
6. A committed Source Handoff is never blindly replayed.
7. Recovery reconstructs fresh Runtime objects.
8. Graph/Policy Ruby objects are supplied by Application code, not persisted.
9. All durable graph participants share one Persistence domain.
10. Application callback delivery is not part of Handoff durability.

## Non-goals

This ADR does not:

- make arbitrary external effects exactly once;
- provide restart-spanning local Handoff callback delivery;
- add distributed transactions across Persistence domains;
- add generic coordination/session/thread identity;
- persist HandoffPolicy/Application code;
- merge Source and Target Agent state.
