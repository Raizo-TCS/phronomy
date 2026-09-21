# ADR-047: Recovered Execution Continuation Contract

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-21
**Refines**: [046-agent-responsibility-layout-and-shared-records](046-agent-responsibility-layout-and-shared-records.md),
[024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md)
and [028-preparing-recovery-replay-contract](028-preparing-recovery-replay-contract.md).

## Problem

Recovery chose a continuation from saved facts but also registered its Agent FSM
and reached five private ExecutionCoordinator entry points through `send`.
Initial execution, approval resume, framework Tool recovery and resolved-result
recovery independently wired parent session completion. Recovery therefore had
to understand the execution owner's terminal and session implementation.

## Decision

### Recovery describes the continuation; execution validates and starts it

Use the execution owner's existing `deliver_on_event_loop` boundary with two
internal command types:

- `RecoverPreparationCommand` identifies the installed execution and expected
  revision, with separate execution and load completion observers.
- `ContinueRecoveredCommand` supplies that identity/revision, a semantic
  continuation, the restored invocation, its materialized projection, the
  execution observer and a failure when applicable.

Recovery still classifies saved facts, requests factual resolution, materializes
saved inputs off EventLoop and restores live invocations on EventLoop. It no
longer registers an Agent FSM, supplies FSM state/event names, owns its terminal
callback, or names private execution-control methods.

The execution owner validates EventLoop affinity, coordinator/Agent ownership,
current revision, nonterminal execution and absence of an installed FSM. It
also checks the continuation's saved phase and invocation identity before any
replacement, admission change or session dispatch. A mismatched continuation
must not replace or release another lifecycle's state. Stale initial preparation
fails both observers without releasing that newer lifecycle.

The execution owner interprets the six continuation intents:

| Intent | Execution-owned action |
| --- | --- |
| Approval rejection | Resume the saved rejected approval and its Tool sessions |
| Framework Tool batch | Resume the authorized framework Tool sessions |
| Saved framework calls | Enter ordinary Provider-result handling |
| Saved Provider output | Enter ordinary Provider-result/output-filter handling |
| Saved Tool results | Enter ordinary Tool-result/follow-up handling |
| Resolved failure | Enter the ordinary terminal persistence barrier |

Delivery is synchronous within the existing EventLoop turn. This is an internal
handover, not an additional queued turn or an Offload operation. Commands are
process-local controls, not persisted records or an application extension SPI.
The existing private terminal/preparation methods remain private.

### One owner wires Agent and Tool sessions

`Agent::ExecutionSessionRunner` owns parent session registration, resumed session
construction, resumed child registration and parent completion wiring. Ordinary
initial execution, approval resume and recovery use it. It reports completion
through an execution-owner-supplied callback; the owner delivers an internal
`SessionFinishedCommand` to itself, including the concrete FSM incarnation and
invocation. This preserves Handoff coordinator dispatch without making the
runner depend on the coordinator's concrete class or command definitions.

The coordinator retains admission, completion observers, stale-callback checks,
physical-quiescence waiting, terminal snapshot creation and persistence. The
runner performs no persistence I/O, saved-fact interpretation, retry decision or
caller-facing result settlement. Parent registration precedes child registration
as before. Its live Runtime/callback handles carry the existing worker-input
restriction marker.

## Compatibility and failure model

Public API snapshots, RBS contracts, stored formats, recovery subjects, approval
decisions and external replay eligibility remain unchanged. A restored rejected
approval now registers its internal execution observer at the same pre-session
boundary used by the other continuation intents; terminal settlement still
occurs only through the coordinator's existing barrier.

Under [018-durability-guarantees-and-failure-model](018-durability-guarantees-and-failure-model.md):

| Subject / property | Provider and condition | Failure / boundary | Result |
| --- | --- | --- | --- |
| Current live execution: reject stale or foreign continuation before state replacement | Execution-owner identity/revision/FSM validation on EventLoop | F2/F3; no X0 dispatch by rejected command | YES |
| Caller completion follows the authoritative terminal outcome | Existing coordinator terminal barrier and quiescence checks; runner reports FSM completion only | F0/F1/F3; existing external effects remain outside transaction | YES under the existing Persistence contract |
| Confirmed recovery state: resume the same logical execution | Recovery classification/materialization plus the execution owner; replay-safe preparation or resolved external facts are required | F1/F4; X0 may have occurred before recovery | CONDITIONAL on the existing operation-specific recovery contract |
| Arbitrary external-effect exactly-once execution | No new external idempotency or transaction protocol | F1/F4 across X0 | NO new guarantee |

The command boundary is process-local validation, not cross-process exclusion.
No broader exactly-once or automatic replay claim follows from this change.

## Verification and remaining work

Exercise rejected commands on a real EventLoop/ExecutionRegistry: wrong owner,
coordinator, revision, installed FSM, terminal state, invocation identity and
continuation phase. Verify both preparation observers and a late session
completion. Existing recovery, approval, F1/F4, output-filter, cancellation,
Handoff and full-suite tests cover valid dispatch and terminal behavior.

ExecutionCoordinator still owns preparation, causal barriers, admission and
terminal operations. This decision removes Recovery's private control coupling
and duplicated session wiring; it does not complete decomposition of that class.
Tool snapshot restoration's direct field coupling, SharedState ownership,
Storage domain responsibilities and Workflow terminal persistence remain
separate work.
