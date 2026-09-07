# ADR-029: Semantic Completion and Application Effect Boundary

## Status

Accepted. V2 revision 2, 2026-09-06.

User approval covers the V2 boundary and the five recovery-contract clarifications.
Acceptance is design authority; it is not a claim of repository integration or test success.

## Date

2026-09-06

## Context

Phronomy durably records Agent semantic execution progress and terminal outcomes.
After a terminal durable commit, Runtime may notify Application code through
`on_event` and settle process-local caller Tasks.

A previous proposal attempted to make terminal callback delivery itself durable
across process loss by storing a pending-delivery descriptor, rediscovering
pending callbacks on `Agent.load`, and durably acknowledging callback attempts.

That approach crossed an architectural boundary.

An arbitrary Application callback may perform an external effect outside
Phronomy's Persistence transaction domain. Phronomy cannot make that effect
exactly once. A process can die after the callback has produced an effect but
before Phronomy records an acknowledgement, so retrying the callback still
requires Application-level idempotency.

Maintaining a framework outbox/ACK protocol therefore does not remove the
Application responsibility that matters most, while it adds persistence indexes,
recovery ordering, acknowledgement reconciliation and callback-specific state to
the Agent execution engine.

## Decision

### 1. Semantic terminal state remains the durable boundary

The existing AgentExecution terminal statuses remain semantic terminal states:

```text
completed
handed_off
failed
cancelled
rejected
blocked
```

Phronomy does not add a callback-only `:completing` status.

A known-successful terminal durable transition ends the logical AgentExecution and
releases normal Agent admission according to ADR-025.

### 2. Terminal semantic result/error evidence is durable

The terminal transaction continues to persist the canonical semantic evidence
already required by Agent durability, including as applicable:

```text
terminal AgentExecution
AgentRoot revision/lifecycle state
Journal terminal facts
result_ref / error_ref
Provider / Tool durable evidence already owned by Agent execution
```

Process loss after this commit must not cause the semantic execution to be rerun
merely because the Application did not observe its completion callback.

### 3. `on_event` is a process-local observation contract

Application `on_event` callbacks are Runtime observations.

Phronomy invokes them in the current process according to the existing callback
error policy, but does not create a restart-spanning delivery obligation.

Phronomy does not persist:

```text
terminal_delivery
delivery_pending
callback attempt_count
callback acknowledgement state
callback/Proc/Task references
```

`Agent.load` does not scan for or redeliver missed terminal callbacks.

### 4. Callback loss after process loss is allowed

The following failure is explicitly permitted:

```text
terminal semantic commit succeeds
  -> process dies before Application callback
  -> callback is not reconstructed/redelivered
```

The semantic outcome remains authoritative and must not be replayed.

An Application that requires restart-spanning notification must implement that
requirement in an Application-owned durable mechanism such as:

```text
outbox
job queue
database transaction/status row
idempotency key
Application Workflow
```

### 5. Callback effects are outside Phronomy's exactly-once guarantee

Phronomy does not claim exactly-once semantics for:

```text
email
webhook
external database mutation
message-broker publication
arbitrary Application callback side effect
```

Applications own idempotency/deduplication appropriate to those systems.

### 6. Caller Tasks remain Runtime-only

A caller-facing Task can observe same-process success/failure and callback policy.
It is not rehydrated after process loss.

No durable state exists solely to recreate or settle a lost caller Task.

### 7. Handoff routing is independent from callback delivery

A Source Agent may terminalize as `:handed_off`.

Durable Handoff responsibility transfer is governed by ADR-030 and does not depend
on whether a local `:handoff` Application event was observed.

Losing the local callback must not lose the Target routing state.

### 8. Read-only outcome access and execution discovery

Applications must be able to query an execution's owner, status and durable
result/error by exact semantic execution ID without invoking/recovering it or
redelivering callbacks. If admission committed before the caller received its ID,
a public discovery path from the known Agent/Team identity must cover retained
terminal as well as active executions. Candidate discovery does not guarantee
request deduplication or unambiguous correlation. Existing retention applies.

Reuse existing APIs where they meet this contract; map missing capabilities only
after baseline inspection. Do not invent a framework outbox or request registry.
See [RC-01](RECOVERY_CONTRACT_CLARIFICATIONS.md#1-rc-01--確定結果の参照と実行の発見).

### 9. Unknown commit outcome and cancellation

A failed read is not proof of absence. A lost commit acknowledgement requires
readback with the same operation/reserved identities before new semantic work.
Unresolved storage uncertainty follows existing Persistence error/retry rules,
not Application factual invention (RC-02).

Stopping observation, losing a caller, or shutting down Runtime does not by
itself request semantic cancellation. Explicit semantic cancellation uses the
existing Agent contract and preserves exact child identities and confirmed
outcomes through its existing terminal/settlement boundaries (RC-04).

The guarantee is reuse of confirmed durable outcomes and recovery of unfinished
executions under the same semantic identity. Unknown external Provider/Tool
effects follow existing Agent Recovery; external effects are not exactly once
(RC-05).

## Persistence / Runtime boundary

The ordering remains:

```text
EventLoop-owned live authority
  -> OffloadPool durable semantic transaction
  -> Persistence commit
  -> EventLoop apply / release admission
  -> optional current-process Application callback
  -> current-process Task settlement
```

No callback acknowledgement transaction follows.

## Relationship to existing ADRs

- Clarifies ADR-018 X0 boundaries: Application effects remain external.
- Preserves ADR-023: Runtime routing identities remain non-durable.
- Preserves ADR-024: EventLoop remains live-state writer.
- Preserves ADR-025: AgentExecution lifetime ends at semantic terminal commit.
- Does not alter ADR-028 preparation replay rules.
- ADR-030/031 may persist additional **semantic coordination facts**, but not
  restart-spanning Application callback delivery.

## Required invariants

1. Known terminal semantic work is never replayed merely because a callback may
   have been lost.
2. No terminal callback-delivery metadata/index/ACK protocol is required.
3. Callbacks, Tasks and external side effects remain Runtime/Application concerns.
4. Agent terminal statuses remain semantic states, not notification states.
5. Phronomy does not claim exactly-once external effects.
6. Read-only result access and retained execution discovery do not trigger work.
7. Read/commit uncertainty and observation loss do not authorize replacement work.

## Non-goals

This ADR does not:

- provide restart-spanning callback delivery;
- provide arbitrary callback-side-effect deduplication;
- recover caller Tasks;
- introduce an Application outbox inside Persistence;
- change Handoff routing semantics;
- change cross-process ownership guarantees.
