# ADR-049: Initial Preparation Worker Ownership

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-22
**Refines**: [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md),
[042-feature-owned-execution-state](042-feature-owned-execution-state.md),
[047-recovered-execution-continuation-contract](047-recovered-execution-continuation-contract.md)
and [048-dispatch-preparation-worker-ownership](048-dispatch-preparation-worker-ownership.md).

## Problem

ExecutionCoordinator still owned initial durable admission, application filtering,
Context preparation, failure persistence and replay of saved preparation inputs.
Its ordinary start and preparing-recovery paths shared persistence work with
EventLoop admission, live state and completion delivery. Simply relocating that
work would leave long methods mixing representation details and control steps.

## Decision

### Preparation owns persistence; the execution owner owns live control

`Agent::InitialPreparation` owns `prepare(Command)` and `recover(RecoveryCommand)`.
Its Command and Result retain the fields of the former Coordinator-owned types.
Coordinator keeps their old constant paths as aliases. Their canonical Ruby names
change; these are internal process-local types, not saved or public API records.

Coordinator retains replay-eligibility capture, Runtime admission, live-owner
checks, Offload submission, completion messages, stale-result validation, live
Agent/Registry updates, session registration and Task/listener settlement.
Preparing recovery captures the execution, root and journal records in an explicit
RecoveryCommand. Result tasks and load completion handles stay on EventLoop.
The worker does not call back into Coordinator or initiate Provider/Tool dispatch.

The worker is marked `WorkerInputRestricted` and holds existing Agent services and
Persistence. It keeps operation state in local variables. This does not remove all
Agent service references or make arbitrary application input/config values deeply
immutable. Approval snapshot isolation remains a later stage.

### Preserve admission outcomes and operation-specific failure boundaries

Input extraction precedes durable admission. An extraction failure returns
`not_established`. During admission, durable busy returns `recovery_required`;
the existing known-conflict/validation exception set returns `not_established`;
other exceptions return `outcome_unknown`. The execution owner preserves the
corresponding Runtime admission release or fail-closed behavior.

Durable admission still creates Execution and advances AgentRoot together, after
validating Team/Subagent/Handoff reservation ownership in the same transaction.
Splitting those ownership checks into named helpers changes no acceptance rule.

For admitted preparation the body reads as filter, stage input, prepare Context,
commit, and materialize. Hooks and ContextPolicy run outside the commit
transaction. Cancellation is checked before filtering, before assembly and after
Policy. The commit revalidates the Agent watermark after Policy returns.

The failure base advances from preparing Execution to active Execution only after
the active commit has returned successfully. A lost active-commit response leaves
the old revision as the failure base. If the active commit did occur, the existing
failure transaction conflicts and rolls back its Journal append; the worker does
not return an unconfirmed terminal result or add a new retry/readback policy.

A post-commit materialization error is terminalized from the known active
revision. Failure persistence atomically appends audit records, saves terminal
Execution and advances AgentRoot. A failure in that transaction, including lost
response, escapes to the execution owner; it is not converted into a confirmed
terminal Result. This initial-preparation contract intentionally differs from
DispatchPreparation's operation-specific uncertain-outcome reconciliation.

`Agent::ExecutionFailure` owns the existing pure error-to-status and status-to-audit
kind mappings. Both initial failure persistence and the remaining terminal worker
use it, avoiding duplicated classification rules. It owns no transaction, live
state or result delivery. Normal/Handoff terminal transaction behavior is unchanged.

### Recovery consumes saved inputs without admitting another execution

The worker first checks the replayable marker, reads current input and rebuilds
config from the saved invocation mode, coordination services and optional canonical
Hash durable_context. The recovered config and durable context remain frozen.
Read failures or invalid durable context escape before admitted preparation;
they do not trigger a failure commit or a speculative retry.

Ordinary start and recovery use the same admitted-preparation operation and Result.
Recovery keeps the same execution identity and does not call durable admission.
Runtime-only approval/listener state is not reconstructed. Existing Coordinator
validation and recovery delivery remain authoritative.

## Guarantees and verification

Using [018-durability-guarantees-and-failure-model](018-durability-guarantees-and-failure-model.md):

| Subject / property | Provider | Failure / boundary | Result |
| --- | --- | --- | --- |
| Same-process Agent starts: fail closed for uncertain/busy admission | Existing Runtime registry plus worker outcome classification | F0/F1/F4; before framework Provider/Tool X0 | YES, unchanged |
| Initial preparation: stale root/revision rejection | Persistence watermark/CAS and failure transaction rollback | F1/F2/F3; before framework Provider/Tool X0 | CONDITIONAL on conforming Persistence |
| Failure transition: Journal, Execution and Root commit together | Existing Persistence transaction | F0/F1; atomicity does not imply response certainty | CONDITIONAL on conforming backend; no new certainty guarantee |
| Preparing recovery: continue the same execution | Existing replay eligibility, saved inputs and owner validation | F4; application preparation may run again | CONDITIONAL on the existing replay-safe preparation contract |
| Arbitrary application or external effects: exactly once | No new exclusion/idempotency protocol | F1/F4 across application-defined X0 | NO new guarantee |

Behavioral tests cover transaction ordering, pre-admission extraction failure,
known admission failure, lost admission/active/failure commit responses,
post-commit materialization failure, cancellation and watermark changes after
Policy, blocked input and replay input restoration/validation/read failure.
Architecture guards include all new worker helpers and exclude control/delivery
dependencies. Existing normal execution, Team/Subagent/Handoff and recovery suites
cover the owner wiring and unchanged coordination checks.

## Remaining work

Approval snapshot isolation and approval persistence, followed by normal/Handoff
outcome worker extraction, remain separate stages. This stage does not finish
Coordinator decomposition or remove all Agent dependency cycles.
