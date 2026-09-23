# ADR-050: Approval Resume Snapshot and Commit Ownership

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-22
**Refines**: [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md),
[047-recovered-execution-continuation-contract](047-recovered-execution-continuation-contract.md)
and [049-initial-preparation-worker-ownership](049-initial-preparation-worker-ownership.md).

## Problem

Approval resume captured a Tool batch into a Coordinator Hash keyed by execution
ID before validating the current approval request. A worker later removed that
entry under a Mutex. Two queued requests could overwrite or consume each other's
snapshot even though the worker commands belonged to distinct operations.
The outer frozen Array also shared mutable String values with the invocation.
The command did not completely describe the recovery facts it would persist.

## Decision

### Validate and capture on EventLoop

ExecutionCoordinator validates the live Agent owner, suspended Execution and
approval request ID before capturing the invocation's canonical Tool snapshot.
It copies and recursively freezes that value tree with `Values::Immutable.copy`
and stores it directly in the operation's `tool_batch_snapshot` field. An absent
invocation gives nil; a present invocation with no children gives a frozen empty
Array. No shared approval snapshot Hash or Mutex remains in either owner.

This applies to canonical recovery facts only. Arbitrary application objects in
config, listener or callback state do not acquire a new deep-copy contract.
The general RecoverySupport snapshot builder keeps its existing contract.

Snapshot isolation was implemented and behaviorally verified before extracting
the persistence operation, so the concurrency fix can be reviewed independently
of the ownership change.

### Persist the captured decision in an operation worker

`Agent::ApprovalResumeCommit#commit` reads as validate the approval target, stage
the captured recovery facts, then persist the decision. Its helpers own record
fields, metadata representation and repository calls. It holds only the Agent ID
and Persistence; all operation state is local. It is `WorkerInputRestricted`.

The existing transaction still writes approval decision Content, adds the
approval_decided record to Execution working records, saves active/resuming
Execution with its expected revision and advances AgentRoot with its expected
revision. Staging metadata preserves the original execution revision so the
durable transition advances it exactly once. A nil snapshot preserves existing
metadata; an empty snapshot replaces the previous Tool batch.

Coordinator retains Runtime admission, Offload submission, completion messages,
late-result validation, live-state replacement, completion waiters, tracing and
SessionRunner resumption. Rejection before Offload submission restores suspended
admission. A commit error keeps admission recovery_required. A late result for
an advanced or cancelled Execution fails only the approval observer and does not
start a session. Existing duplicate-approval acceptance and CAS rules are unchanged.

The worker does not read back uncertain results, retry a transaction, contact
Provider/Tool adapters or invoke application callbacks. A lost commit response
escapes as an error; the owner follows the existing recovery-required path.
Persistence atomicity must not be presented as certainty about that response.

### Internal type compatibility

Command and Result are owned by ApprovalResumeCommit. Coordinator retains
`ResumeCommitCommand` and `ResumeCommitResult` as aliases to those exact classes.
Their canonical Ruby names change to `ApprovalResumeCommit::Command` and
`ApprovalResumeCommit::Result`. Command appends the required internal field
`tool_batch_snapshot`; Result retains its existing members. Internal positional
construction/reflection is consequently not unchanged. These types are neither
public API nor durable records. Saved schema and public approval API stay unchanged.

## Guarantees and verification

Using [ADR-018](018-durability-guarantees-and-failure-model.md):

| Subject / property | Provider | Failure / boundary | Result |
| --- | --- | --- | --- |
| Queued approval operation retains its captured facts | EventLoop validation and independent immutable Command values | F0/F2/F3; before Provider/Tool X0 | YES for canonical Tool snapshot values |
| Approval transition is atomic (G5), stale writes are rejected (G8) | Existing Persistence transaction and Execution/Root CAS | F2; no framework X0 in this worker | CONDITIONAL on conforming backend |
| Unknown approval commit is not treated as confirmed resumption | Worker error propagation and owner recovery_required admission | F1; no new worker X0 | YES; no new commit certainty or readback guarantee |
| Restored approval waiting continues the same execution (G4) | Existing recovery reconstruction and validated resume path | F4; later Tool work may cross X0 | CONDITIONAL on existing recovery/integration contracts |
| Cross-process exclusion (G7), external duplicate prevention (G9), exactly once (G10) | No new protocol supplied by this change | F1/F2/F4 across X0 | NO new guarantee |

Tests cover mutation after capture, reversed worker order, stale and invalid
requests, rejected submission, empty/absent batches, successive approvals,
approval/denial persistence, Execution and Root conflicts, transaction response
loss and stale results after cancellation or a newer approval. Existing recovery
integration tests restore approval waiting and resume both approval and denial.
The unit fault injections are not a hard-process-loss or real external-service test.
Architecture guards inspect the worker helpers for live-control dependencies.

## Remaining work

Normal terminal persistence and Handoff terminal persistence remain coupled in
ExecutionCoordinator and its subclass. They are the next extraction stage and
must be designed together. This change does not complete Coordinator decomposition
or eliminate Agent dependency cycles.
