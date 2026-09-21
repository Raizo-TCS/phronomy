# ADR-042: Feature-Owned Execution State on EventLoop

**Status**: Accepted
**Date**: 2026-09-21
**Amends**: [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md), [025-process-local-agent-ownership-and-runtime-admission](025-process-local-agent-ownership-and-runtime-admission.md), [026-workflow-runtime-admission-and-durable-terminal-barrier](026-workflow-runtime-admission-and-durable-terminal-barrier.md) for implementation ownership, delivery and shutdown admission
**Complements**: [041-feature-owned-identity-registries](041-feature-owned-identity-registries.md)

## Problem

EventLoop implemented Agent admissions, execution snapshots, completion waiters,
physical-work tracking and recovery errors, as well as Workflow segment
admissions, routing and recovery-required state. Its dispatcher selected Agent
coordinators and Workflow runners. These are feature policies inside Engine;
retaining them behind dynamic calls would not remove the ownership problem.

## Decision

`Agent::ExecutionRegistry` owns Agent admission, immutable execution entries,
read-only owner lookup, completion waiters and physical quiescence supervision.
`WorkflowExecutionRegistry`, under `workflow/execution/`, owns Workflow segment
admission, instance-to-session routing and recovery-required admissions.
Both retain the existing semantic identities, exceptions and durable barriers.
Neither registry is the Runtime-lifetime Agent/Team identity registry of ADR-041.

All normal feature state mutation still runs on the one EventLoop thread.
Workers only enqueue results or physical-completion notifications. The Engine
`ExecutionReceiver` base defines an internal registration/delivery/lifecycle
contract; it is not an application callback or plugin SPI. Feature code creates
its receiver lazily. Engine never constructs a concrete feature receiver and
does not interpret feature IDs, commands, admission states or exceptions.
Runtime provides only a non-creating EventLoop lookup for feature inspection.

### Registration, delivery and drain

One EventLoop strongly retains one receiver per feature key. Registration is
allowed only while running. Existing lookup never reopens admission or creates
another loop. A receiver is bound to its original EventLoop.

The generic FIFO delivery contains a registered receiver, immutable command,
admission flag and optional caller completion. An in-memory envelope token
identifies only a pending delivery; it is not durable identity, a generation
counter, or authority for accepting a semantic result. Feature coordinators
continue to validate execution revisions, operation IDs and current FSM state.

Engine closes new receiver registration and new admission deliveries before
testing idleness. Agent start/approval resume, Recovery install/resolve and
Workflow start/resume are new requests at this boundary. A request queued before
drain remains accepted and may establish its feature admission during drain.
Existing worker results, physical-completion notifications, cancellation and
session events may continue while the loop drains. A continuation cannot claim
a new admission after the gate closes.

Engine counts a queued or currently dispatching receiver message until dispatch
finishes. This covers the interval before the feature admission exists. Feature
idleness covers admission-before-FSM-registration and logical-completion-before-
physical-quiescence intervals. Suspended/recovery-required admissions retain
their exclusion without indefinitely preventing shutdown.

Feature state reads/writes and Engine idleness use the same lifecycle mutex.
`idle?` is called with that lock held and must be short, nonblocking, and must
not call Runtime or reacquire the lock. Other state operations use the shared
synchronization helper. Delivery, TaskResult callbacks and receiver shutdown
execute outside the lock. Workflow routing resolves the admission and enqueues
to the currently admitted FSM under that same lock; it does not use a stale
lookup followed by an independent enqueue.

Generic FSM registration may attach its receiver. When the FSM reports
recovery-required retirement, Engine notifies that receiver; Workflow decides
how to retain its logical admission. Engine does not inspect Workflow state.

### Failure and final invalidation

On dispatcher failure, new delivery is closed. Engine fails current/queued
request completions and FSM waiters, then notifies every receiver with the
failure on the failing EventLoop thread. Each receiver clears its own state.

On normal shutdown, Engine notifies receivers only after its thread has joined.
This is exclusive final reference invalidation, not management-thread execution
progression. Agent fails retained nonterminal completion waiters with
`ExecutionRehydrationRequiredError`; Engine never selects that exception.
Workflow retains the prior behavior of not fabricating a terminal result from
an uncertain durable outcome. A receiver cleanup exception does not prevent
later receivers from being visited; cleanup is incomplete and default Runtime
replacement is refused. A loop still alive at timeout is not invalidated.

## Guarantees and limits

| Subject/property | Provider | Failure/boundary | Result and condition |
|---|---|---|---|
| Same-process exclusion and single-writer live state | Feature registries, EventLoop delivery and shared lifecycle lock | F2/F3; no X0 | YES within one Runtime; no cross-process exclusion |
| Clean shutdown waits for accepted admission and supervised physical work | Engine pending-delivery count plus feature idle predicates and OffloadPool completion | F0/F3; may observe work that crossed X0 | CONDITIONAL on work becoming quiescent before shutdown deadlines; no external effect rollback |
| Failed/terminated loop cannot continue authoritative live mutation | Closed delivery gate, loop-thread checks and exclusive receiver invalidation | F0/F3/F4; no new X0 | YES for framework-managed live state; process loss requires existing durable recovery |
| Uncertain durable execution is not released as successful | Existing Agent/Workflow durable barriers and recovery states | F1/F4; X0 unchanged | CONDITIONAL on the existing Persistence/reconciliation contracts; this change adds no durability or exactly-once guarantee |

Public Agent/Workflow APIs, persisted formats, TaskResult semantics and the
OffloadPool worker implementation are unchanged. Internal EventLoop feature
methods and Runtime Agent forwarding methods are removed without aliases.

## Rejected alternatives

- Move Agent errors to Engine/common while keeping Agent decisions in Engine.
- Have Engine construct concrete feature registries or choose coordinators.
- Move only static references while retaining Workflow-specific maps/dispatch.
- Split feature and idle locks, allowing shutdown to miss newly admitted work.
- Invoke arbitrary callbacks without registered receiver and lifecycle rules.
- Replace OffloadPool physical-completion supervision with new worker threads.
