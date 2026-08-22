# ADR-018: Durability Guarantees and Failure Model Vocabulary

## Status

Accepted.

## Date

2026-08-23

## Context

Phronomy already has concrete durability, transaction, concurrency,
cancellation and fault-handling behavior, but terms such as "durable",
"recoverable", "safe", "conflict protection" and "exactly once" can describe
materially different guarantees.

That ambiguity is unsafe for later recovery and distributed-ownership work.
A durable record being readable after restart does not imply that a lost
execution can resume. Transaction atomicity does not imply that a caller can
always determine whether a commit occurred. Optimistic conflict detection
does not imply distributed exclusion. Neither durability nor exclusion
implies exactly-once execution of external side effects.

This ADR establishes the repository-wide guarantee vocabulary and failure
taxonomy used by architecture review, fault-injection review and downstream
Architecture Change Sets.

It is a normative **target architecture contract**. It does not claim that
every target guarantee below is already implemented. Known implementation
gaps remain explicit downstream reconciliation work.

## Decision

### 1. Guarantee statements name the subject, property and provider

Do not use a bare statement such as:

```text
recoverable = yes
safe = yes
durable = yes
```

A guarantee statement must make clear:

```text
guarantee subject + guarantee property
    provided / enforced by
guarantee provider / contract
```

For example:

```text
Agent logical state:
  logical-state rehydration = YES
  provided by supported Agent load/hydration + Persistence

In-flight external Tool execution:
  execution resumption = CONDITIONAL
  provided only when its recovery/integration contract supports safe
  reconciliation or replay
```

### 2. Canonical guarantee vocabulary

The following ten terms are distinct guarantees.

#### G1 — durable state persistence

**Subject:** semantic state/records explicitly defined as durable Phronomy
state, such as AgentRoot, JournalRecord, AgentExecution, durable Workflow
checkpoints and content-addressed Content.

**Guarantee:** after a known-successful Persistence commit, the state is held
in durable storage independently of process-local Runtime object lifetime.

**Provider:** Phronomy Persistence contract plus a conforming backend.

Process-local objects such as FSMSession, Activation, AgentInvocation, Task
and EventLoop queue entries are not covered by this guarantee.

#### G2 — durable-state restart readability

**Subject:** state/records already durably committed.

**Guarantee:** after Phronomy Runtime/process restart, the state can be read
through the supported Persistence API.

**Provider:** Persistence contract plus backend.

Readability does not imply logical-state rehydration or execution resumption.

#### G3 — logical-state rehydration

**Subject:** state of a logical entity with durable identity.

**Guarantee:** supported Phronomy APIs can construct usable live/domain state
representing the same logical entity from confirmed durable state, without
requiring the old process-local Ruby/Runtime objects.

**Provider:** Phronomy load/hydration semantics plus Persistence.

Rehydration does not restore the pre-crash object graph and does not itself
imply execution resumption.

#### G4 — execution resumption

**Subject:** an unfinished logical execution/continuation.

**Guarantee:** supported recovery/resume semantics can continue the same
logical execution from durable recovery state without blindly re-executing
semantic work already known to have completed.

**Provider:** Phronomy Runtime/recovery/resume semantics together with the
relevant operation-specific recovery contracts.

A durable AgentExecution record is necessary recovery evidence but is not,
by itself, an execution-resumption guarantee.

#### G5 — durable-transition atomicity

**Subject:** one semantic durable transition whose durable mutations are
defined as one transaction boundary.

**Guarantee:** durable mutations in that transition commit all-or-nothing.

**Provider:** Persistence transaction contract plus backend.

Atomicity does not guarantee that the caller can always know a commit's
outcome after a transport/database failure.

#### G6 — same-process competing-execution exclusion

**Subject:** competing semantic executions for one logical entity that must
not be admitted concurrently.

**Guarantee:** one Phronomy Runtime/process does not concurrently admit the
prohibited competing executions.

**Provider:** Phronomy Runtime/admission semantics and, where applicable,
process-local/backend admission mechanics.

This does not exclude immutable reads or observation.

#### G7 — cross-process competing-execution exclusion

**Subject:** the same competing executions across multiple processes,
containers, replicas or Runtime instances.

**Guarantee:** prohibited competing executions are not simultaneously
admitted across those environments.

**Provider:** Phronomy plus stable routing/partitioning or a cross-process
coordination mechanism that establishes exclusive ownership.

A process-local registry, Mutex or optimistic CAS alone is not this guarantee.

#### G8 — stale durable-transition conflict detection

**Subject:** a durable write/transition based on a stale revision, Journal
position, watermark or equivalent durable base.

**Guarantee:** the stale transition is detected and rejected instead of
silently overwriting newer durable state.

**Provider:** Persistence optimistic revision/CAS/watermark contract plus the
Phronomy layer that uses it correctly.

Conflict detection is not competing-execution exclusion and cannot roll back
an already-performed external side effect.

#### G9 — duplicate external-side-effect prevention

**Subject:** one semantic side effect outside Phronomy's durable transaction
domain, such as an external API update, payment, email, external database
mutation or application callback effect.

**Guarantee:** under the defined failure/retry/recovery conditions, the same
semantic side effect does not become effective more than once.

**Provider:** Phronomy semantic identity/retry/recovery behavior together
with whatever external idempotency/deduplication protocol is required.

A semantic ID existing in Phronomy does not, by itself, provide this guarantee.

#### G10 — exactly-once external-side-effect execution

**Subject:** one semantic external side effect.

**Guarantee:** within the stated failure model the side effect becomes
effective exactly once: neither zero times nor more than once.

**Provider:** never assumed to be Phronomy alone. It requires sufficient
external-system protocol, idempotency and/or transaction coordination.

Duplicate prevention is weaker than exactly-once: a system can avoid
duplicates while still permitting zero executions after failure.

### 3. Guarantee terms are not an implication hierarchy

These guarantees do not imply each other unless another architecture contract
says so.

In particular:

```text
durable state persistence
    != durable-state restart readability
    != logical-state rehydration
    != execution resumption

durable-transition atomicity
    != commit outcome certainty

same-process competing-execution exclusion
    != cross-process competing-execution exclusion

stale durable-transition conflict detection
    != competing-execution exclusion

cross-process competing-execution exclusion
    != duplicate external-side-effect prevention
    != exactly-once external-side-effect execution
```

`durable state`, `durable transition`, and `durable barrier` also remain
separate architecture concepts. A durable barrier is continuation ordering
around a confirmed durable outcome; it is not EventLoop-wide blocking and
does not create X0 external-effect atomicity.

### 4. Canonical failure taxonomy

`F0` through `F4` are identifiers, not a severity scale, execution-stage
ordering, containment hierarchy or recovery-difficulty ranking. One scenario
may match more than one failure class.

#### F0 — Operation Failure

**Analysis subject:** one semantic/runtime operation.

The operation starts but does not reach its contract-defined normal
completion. Exceptions, explicit errors, rejection, cancellation and timeout
are possible concrete mechanisms.

F0 means failure is known; it must not be confused with F1, where the outcome
itself is unknown.

#### F1 — Outcome Uncertainty

**Analysis subject:** Phronomy's knowledge about an operation, durable
transition or external effect outcome.

Phronomy cannot determine whether the operation succeeded, whether a durable
transition committed, or whether an external effect occurred.

Observing an error/connection loss does not prove that the remote operation
did not occur or that a commit did not happen.

F1 therefore requires reconciliation/recovery treatment rather than blind
inference from the failure response.

#### F2 — Concurrency Conflict

**Analysis subject:** multiple actors/operations competing over the same
logical entity, state or execution lifecycle.

The class identifies the conflict. It does not decide whether architecture
prevents admission, detects stale state after admission, or permits the
concurrency.

#### F3 — Asynchronous Lifecycle Mismatch

**Analysis subject:** an asynchronous completion and the lifecycle/owner that
could accept it.

The receiver's execution context, FSMSession, operation generation or
authority has ended, cancelled, resumed, changed or been replaced before the
completion arrives. Late completion, duplicate completion and an event
targeting an old session are examples.

#### F4 — Execution-Environment Loss

**Analysis subject:** process-local Runtime state supporting a logical
execution.

Runtime/process loss makes live objects such as Activation,
AgentInvocation, FSMSession, Task, EventLoop queue and Runtime-local admission
unavailable.

F4 does not imply that confirmed durable state was lost. It is the primary
reason recovery must not depend on old live Runtime objects.

#### X0 — External Effect Boundary

`X0` is **not a failure class**. It is a boundary label.

X0 identifies semantic effects outside Phronomy's durable transaction domain,
including Tool/provider/application/remote-system effects. Unless an explicit
protocol provides stronger coordination, such effects are not atomic with a
Phronomy Persistence transaction.

F0-F4 can occur on either side of X0. Combining X0 with F1, retry, recovery or
competing execution is where duplicate-prevention and exactly-once questions
become significant.

### 5. Failure-model assumptions

Core guarantee analysis assumes:

- Persistence backends honor the Phronomy Persistence contract.
- Tool, LLMAdapter and application extension code honor their published
  contracts.
- process-local Runtime state may be lost under F4.
- confirmed durable backend state survives according to the backend's own
  durability guarantee.
- OS, database, network and external services may fail.
- X0 external side effects and Phronomy Persistence commits are not one atomic
  transaction unless a specific protocol says otherwise.

Storage-media destruction, backup/restore policy, multi-region disaster
recovery and malicious/contract-violating extension code are outside the
general Phronomy core guarantee.

### 6. Final guarantee matrix

The matrix uses:

```text
YES          baseline target guarantee
CONDITIONAL  guarantee only when the stated additional condition holds
NO           not a baseline guarantee
N/A          not applicable to that subject
```

A `CONDITIONAL` row is incomplete without its condition.

#### Durable state

| Subject | Durable persistence | Restart readability | Logical rehydration |
|---|---|---|---|
| Durable Agent state | **YES** | **YES** | **YES** |
| AgentExecution / Journal | **YES** | **YES** | **YES** — as logical continuation state/evidence |
| Durable Workflow checkpoint | **YES** | **YES** | **YES** |
| Ephemeral Workflow state | **NO** | **NO** | **NO** |
| Runtime objects (FSMSession, Activation, Task, etc.) | **NO** | **NO** | **N/A** — object itself is not rehydrated |

Logical rehydration reconstructs current logical/domain state from confirmed
durable state; it does not restore the old Ruby object graph.

#### Execution resumption

| Subject | Guarantee |
|---|---|
| Restart-safe HITL durable continuation | **YES** |
| Durable Workflow continuation | **CONDITIONAL** — dependency consistency and ownership requirements must hold |
| Process loss with no unresolved external semantic operation | **YES** |
| In-flight LLM Provider Call | **CONDITIONAL** — operation recovery classification/integration contract |
| In-flight Tool Execution | **CONDITIONAL** — operation recovery classification/integration contract |
| Outcome uncertain and not safely resolvable by Phronomy/integration contract | **CONDITIONAL** — Application resolution is required |
| Terminal Execution | **N/A** |

`logical-state rehydration = YES` never means unconditional automatic resume.
Ownership, durable dependency consistency and pending-operation recovery
classification govern safe continuation.

#### Durable transition and concurrency

| Guarantee | Agent | Workflow |
|---|---|---|
| Durable-transition atomicity | **YES** | **YES** — for a defined durable transition |
| Same-process competing-execution exclusion | **YES** | **YES** |
| Cross-process competing-execution exclusion | **CONDITIONAL** | **CONDITIONAL** |
| Stale durable-transition conflict detection | **YES** | **YES** |

Cross-process exclusion requires stable application routing/partitioning or a
cross-process coordinator that provides exclusive ownership. Persistence CAS
or revision checking alone is not enough.

#### Cancellation and Task invariants

| Subject | Guarantee |
|---|---|
| Prevent late result from updating live state after cancellation/authority loss | **YES** |
| Cancellation request physically terminates the worker/external operation | **NO** |
| Runtime supervises cancelling/cancelled work until quiescence or operation-specific safe detach | **YES** |
| Waiter-local timeout cancels the Execution | **NO** |
| Semantic deadline invalidates result authority | **YES** |
| Caller Task settlement coincides with the authoritative completion boundary | **YES** |
| Runtime Task object itself is recovered after restart | **NO** |

#### External side effects

| Guarantee | Baseline |
|---|---|
| Retry eligibility is based on operation-specific contract and outcome certainty | **YES** |
| Blind automatic retry when safety is not established | **NO** |
| Reconciliation capability is usable when the integration provides it | **YES** |
| Arbitrary external-effect duplicate prevention | **CONDITIONAL** — external idempotency/deduplication or equivalent contract is required |
| Arbitrary external-effect exactly-once execution | **NO** |

### 7. Review and test usage

Architecture-sensitive failure/recovery/concurrency changes must state:

1. the guarantee subject;
2. the guarantee property from G1-G10;
3. the provider/condition that makes the guarantee true;
4. the applicable failure class(es) F0-F4;
5. whether X0 is crossed;
6. whether the claimed result is YES, CONDITIONAL or NO in the target matrix.

Fault-injection tests should identify the failure class/boundary they exercise.
A test that observes F0 must not be presented as F1 reconciliation coverage.
A graceful Runtime shutdown test is not automatically F4 recovery coverage.
A Tool failure test crossing X0 does not prove duplicate prevention or
exactly-once behavior.

The taxonomy is architecture/test vocabulary. This ADR does **not** add a
public `FailureClass` enum, public guarantee-level enum or one-error-class-per-
failure-category hierarchy. Observable public errors are designed only where
a concrete API contract requires them.

### 8. Relationship to current implementation and downstream ACS work

This ADR intentionally separates vocabulary from implementation mechanics.

Known downstream responsibility includes:

- ACS-14: cross-process ownership/fencing and G7 conditions.
- ACS-15: F1/F4 durable recovery, reconciliation and execution resumption.
- ACS-16: cancellation supervision and caller-facing Task settlement.
- ACS-17: X0 semantic retry, outcome certainty, causal durable barriers and
  duplicate/side-effect guarantees.
- ACS-02: final explanatory architecture guarantee matrix/document placement.

Existing ADRs remain authoritative for their current scopes:

- ADR-010: EventLoop/FSMSession/Task/Offload concurrency boundary.
- `011-delegate-transport-policy-to-adapters`: transport retry ownership.
- ADR-012: canonical Journal/Manifest authority.
- ADR-014: unified durable Persistence intent until coherent successor
  decisions replace stale portions.
- ADR-017: repository Design Authority/governance.

This ADR does not silently declare known implementation gaps resolved. Later
ACS changes use this vocabulary to state exactly which target guarantee they
implement.

## Consequences

### Positive

- "durable", "recoverable" and "safe" can no longer hide different guarantees.
- F0 known failure and F1 outcome uncertainty are reviewably distinct.
- cross-process exclusion cannot be mistaken for optimistic conflict
  detection.
- external duplicate prevention cannot be inferred from a semantic ID alone.
- exactly-once external effects remain explicitly outside the unconditional
  Phronomy baseline.
- recovery/fencing/cancellation/retry work shares one acceptance vocabulary.

### Trade-offs

- architecture-sensitive PRs must state guarantees and failure conditions more
  precisely.
- the normative matrix can temporarily describe target behavior that current
  source has not yet reconciled; those gaps must remain explicit.
- deployment-specific details are not encoded in this ADR. The ADR fixes the
  semantic conditions; deployment documentation explains how a particular
  deployment satisfies them.

## Non-goals

This ADR does not:

- introduce public failure/guarantee enums;
- add new Runtime/Persistence error classes merely to mirror F0-F4;
- implement cross-process coordination;
- implement restart recovery/reconciliation;
- redesign cancellation/Task settlement;
- introduce semantic external-operation retry;
- claim arbitrary external exactly-once execution;
- perform the final ACS-02 architecture-document migration.
