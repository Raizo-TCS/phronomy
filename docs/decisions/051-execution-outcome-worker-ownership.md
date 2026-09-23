# ADR-051: Execution Outcome Worker Ownership

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-22
**Refines**: [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md),
[030-agent-handoff-domain-and-durable-responsibility](030-agent-handoff-domain-and-durable-responsibility.md),
[047-recovered-execution-continuation-contract](047-recovered-execution-continuation-contract.md)
and [050-approval-resume-snapshot-and-commit-ownership](050-approval-resume-snapshot-and-commit-ownership.md).

## Problem

ExecutionCoordinator owned both EventLoop execution control and Offload result
persistence. HandoffExecutionCoordinator overrode outcome selection and depended
on its parent's transaction helpers. Extracting only one side would preserve
that hidden dependency or accidentally change Handoff precedence. Moving the
long bodies unchanged would also leave persistence policy mixed with individual
record fields.

## Decision

### Select and persist outcomes in operation workers

`Agent::ExecutionOutcomeCommitter#commit_outcome` selects completion, failure,
approval suspension or owned-child waiting from a captured command. It handles
persistence exceptions through the existing operation-specific readback rules.
`Agent::HandoffOutcomeCommitter` specializes that selection and atomic Source
transfer, sharing ordinary completion, failure and suspension persistence.
Handoff selection retains its separate callback/error/suspension/transfer order;
it does not acquire the ordinary worker's child-coordination wait branch.

HandoffExecutionCoordinator retains its class identity and inheritance, but now
only selects the Handoff worker. This selection is internal, not a public SPI.
Coordinator captures input, submits the worker, validates the returned revision
and session, applies live state and delivers results. Worker code never calls
back into Coordinator. Command state and intermediate results remain local to
one operation; workers hold only Agent service context and Persistence.

Agent context is still required by the existing coordination hook, error
translation, saved Manifest reader and transcript materializer. This is not a
claim that all Agent references or dependency cycles have been removed.
`WorkerInputRestricted` marks both worker types; it is not a recursive validator
of arbitrary application-owned values.

### Keep transactions visible in the purpose-level methods

`commit_completed` encodes completion records, appends Journal, saves Execution
and coordination, advances Root and materializes the caller-facing transcript
inside one transaction, then constructs the result. Record fields and repository
arguments belong to its helpers. Transcript materialization stays inside the
transaction so failure rolls back the transition.

`commit_failed_outcome` persists audit-only records and the translated failure.
The Context revision stays unchanged because none of those records is a Context
candidate. Completion and Handoff advance Context only if the appended records
contain a candidate. Suspension retains its records in Execution working state,
advances Root to suspended and does not append Journal or advance Context.

`commit_handed_off` validates Source routing and cancellation, persists projected
Context, transfers routing to a deterministic Target execution ID, and saves
Source Journal, Execution and Root in one transaction. Target definition lookup
uses the transaction view; the existing saved Manifest reader keeps its service
context. Target completion/failure stabilizes routing inside its own existing
terminal transaction. No Provider/Tool dispatch or application delivery moves
into these workers.

### Preserve the distinct readback contracts

| Operation | Existing confirmation rule after an exception | Consequence |
| --- | --- | --- |
| Ordinary/Handoff terminal | Same Agent, terminal Execution, expected revision + 1; then load saved Root, Journal and result | Reuse the persisted outcome; do not write a second terminal transition |
| Child-coordination wait | Complete saved Execution payload equals the intended waiting record | Return that nonterminal wait; active status alone does not establish a match |
| Approval suspension | It is nonterminal, so terminal readback does not confirm it | Propagate uncertain completion to the owner |

Terminal confirmation is deliberately not changed to DispatchPreparation's
full intended-payload comparison. Missing, active, mismatched or unreadable
results do not authorize another write. Readback errors retain their existing
propagation behavior. Recovered success retains the existing smaller result
shape; recovered failures use `RecoverySupport.error_from_failure`, including
its generic Phronomy::Error representation. This extraction does not normalize
those results or introduce a stronger commit-certainty protocol.

### Preserve EventLoop result authority and delivery

The owner still waits for physical work quiescence before terminal persistence.
A stale result changes no live state, admission or Task. Completed/failed/Handoff
results release ownership and deliver their existing events before settling
waiters. Suspension retains admission and leaves the original Task pending;
exact observers receive the existing approval-required failure. Child waiting
releases ownership and fails waiters with recovery required.

A worker error for ordinary execution retains recovery_required admission and
pending waiters. The existing coordination-metadata error path releases the
owner and fails waiters. Those branches are not merged into unconditional cleanup.
Live Handoff request/Manifest delivery handles remain outside the worker command.

### Internal types

ExecutionOutcomeCommitter owns `Command`, `Outcome`, `TerminalView` and
`HandoffTerminalView`. Coordinator retains its previous constant paths as aliases
to the same classes. All four member lists stay unchanged; their canonical Ruby
names change. TerminalDelivery and TerminalCommitReady remain owner-local.
These types are internal and are not serialized by class name. Public API, saved
schemas, Agent/Handoff Coordinator identity and caller selection remain unchanged.

## Guarantees and verification

Using [ADR-018](018-durability-guarantees-and-failure-model.md):

| Subject / property | Provider | Failure / boundary | Result |
| --- | --- | --- | --- |
| Terminal or Handoff transition atomicity (G5), stale write rejection (G8) | Existing transaction and repository CAS | F0/F2; no new framework X0 | CONDITIONAL on conforming Persistence backend |
| No second terminal write after uncertain response | Operation-specific worker readback and owner recovery path | F1; no new worker X0 | YES; no stronger outcome-certainty guarantee |
| Current execution alone may apply worker results | Existing EventLoop owner/revision/session guards | F2/F3 and delayed completion | YES within the same Runtime ownership contract |
| Logical continuation from saved Source/Target state (G4) | Existing Handoff recovery and exact Target identity | F4; later execution can cross X0 | CONDITIONAL on existing recovery contracts |
| Cross-process exclusion (G7), external duplicate prevention (G9), exactly once (G10) | No new protocol added | F1/F2/F4 across X0 | NO new guarantee |

Behavior tests exercise completion/rejection, failure categories, suspension,
transaction rollback, Root CAS, response loss and readback mismatches/failures,
child waiting, atomic Source transfer, routing conflict/cancellation and Target
completion/failure. Existing suites cover physical quiescence, stale results,
callback policy, approval recovery and durable Handoff recovery. Unit fault
injections do not represent real process loss or live external service failures.
Architecture guards now inspect the actual workers and disallow repository
reloads in Coordinator without the old terminal-helper exceptions.

## Owner-control review (2026-09-22)

The fifth stage keeps one execution owner and makes its remaining result paths
read as validation, state application and continuation/delivery. Preparation
recovery separates failed-outcome settlement from session restart. Approval
resume separates committed-state installation and tracing from FSM entry.
Terminal results retain visible outcome selection while private methods handle
the distinct waiting, suspension, completion, Handoff and failure deliveries.
Only the identical execution/admission release is shared across terminal paths.
Initial preparation snapshot construction is named explicitly; start/resume
admission flags, submission flags and their rescue decisions remain together.

No transaction, authority condition, failure policy, public type or class owner
changes. Direct Ready delivery tests run on the real EventLoop/ExecutionRegistry
and check stale-result isolation, state-before-notification, notification-before-
settlement, fallback waiters, suspension, uncertainty and recovery/resume failure
boundaries. These tests also pass against the preceding implementation, documenting
preserved behavior rather than a new contract. F0/F1/F3 are injected locally;
no new X0 operation or stronger F4 guarantee is claimed.

## Remaining work

The execution-owner decomposition and final readability review are implemented.
Tool restoration, SharedState, Storage domain responsibilities and Workflow
terminal ownership remain separate work items. Further owner splitting needs a
concrete responsibility or failure-boundary reason; file length alone is not one.
