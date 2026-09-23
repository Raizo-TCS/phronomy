# ADR-048: Dispatch Preparation Worker Ownership

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-22
**Refines**: [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md),
[042-feature-owned-execution-state](042-feature-owned-execution-state.md)
and [047-recovered-execution-continuation-contract](047-recovered-execution-continuation-contract.md).

## Problem

ExecutionCoordinator mixed EventLoop ownership and application result delivery
with the Persistence operations required before Provider/Tool dispatch. Moving
whole methods alone would leave the Provider operation mixing control steps,
metadata representation, transactions, application policy and materialization.
Its worker also used input/result types nested under the execution owner, which
would create a reverse dependency after extraction.

## Decision

### The execution owner captures, submits and applies

ExecutionCoordinator keeps current Agent/invocation/FSM validation, operation
capture, Offload submission, Ready delivery, semantic revision/phase checks,
snapshot acknowledgment and physical Provider/Tool dispatch. These responsibilities
remain on their existing threads and in their existing order. Ordinary and
recovered execution keep the same owner and continuation contract.

`Agent::DispatchPreparation` owns four internal worker operations:

- `prepare_provider`: stage the next call, encode runtime records, prepare the
  Context, commit prerequisites and materialize the confirmed input.
- `prepare_tools`: encode runtime records and save pending Tool recovery facts.
- `reconcile_provider`: read back the execution, classify the exact saved state
  and restore input only for the confirmed intended result.
- `reconcile_tools`: read back and classify the exact saved state.

The worker returns values and never schedules work, advances the live Registry,
acknowledges invocation snapshots, starts Provider/Tool calls, or settles Tasks.
It does not refer back to ExecutionCoordinator or its private methods. The
Coordinator creates the worker with the existing Agent service context and its
Persistence instance. Agent hooks, ContextAssembler and coordination preparation
retain their existing service contracts; this is not removal of all Agent
references. The worker is marked `WorkerInputRestricted` because it retains
framework service handles. Per-operation inputs/results remain local variables.

### Preserve the operation-specific persistence boundaries

Provider preparation has two transactions with application hooks/ContextPolicy
between them. The first can encode content-addressed records but does not advance
Execution. The second rechecks the local Agent watermark, finalizes the Manifest
and saves the Execution. Cancellation is checked after Policy and before that
second transaction. Tool preparation retains its single transaction.

Only an exception in the guarded save transaction, after an intended result was
captured and outside the existing known-failure classes, becomes an unknown
outcome. Encoding failures and application Policy failures do not become an
uncertain execution save. Post-commit materialization failure returns the saved
Execution together with an error, so the owner still applies/acknowledges the
known committed snapshot before reporting setup failure.

Reconciliation compares both revision and complete execution contents. It returns
`committed` only for the intended state, `not_committed` only for the exact original
state, and `conflict` otherwise. Read failures propagate. It never retries the
write or authorizes dispatch by itself. Terminal and coordination-wait
reconciliation remain separate and retain their different acceptance criteria.

The watermark rule remains owned by Persistence's `assert_agent_watermark!`.
The worker and the remaining initial-preparation code only map captured Root
fields to that contract; neither implements a second version of the rule.

### Names describe the purpose; bodies describe its immediate steps

The Provider entry reads as stage, encode, prepare Context, commit, materialize.
Private helpers own metadata keys, record fields and value construction. The
Coordinator's dispatch entry reads as validate, capture, submit. Transaction
and rescue scopes stay explicit in the operations that own them. We do not use
one-line delegation chains or a generic execution framework to reduce line counts.

### Types belong to the operation boundary

DispatchPreparation owns Provider/Tool commands, reconciliation commands and
their results. ExecutionCoordinator retains its existing eight nested constant
paths as aliases to these types; Ready messages and live delivery remain in the
Coordinator. Its private uncertainty exception constant is also an alias.

The aliases preserve construction, members and shared type identity, but the
canonical Ruby class names now belong to DispatchPreparation. These are internal,
process-local types, not persisted records or public extension contracts. This
change makes no promise to preserve their former reflected names. Product API
snapshots, saved formats, public exception contracts and recovery eligibility
remain unchanged.

## Failure model and verification

Using [018-durability-guarantees-and-failure-model](018-durability-guarantees-and-failure-model.md):

| Subject / property | Provider and condition | Failure / boundary | Result |
| --- | --- | --- | --- |
| Current execution: apply only a matching preparation result | Existing EventLoop owner, revision and FSM checks | F2/F3; no new X0 dispatch from stale results | YES, unchanged |
| Provider/Tool dispatch: confirmed durable prerequisites precede physical dispatch | Operation-specific commit/readback plus owner apply; conforming Persistence is required | F0/F1; this barrier precedes the next X0 call | CONDITIONAL on confirming the intended durable state and current live ownership |
| Application Policy: no preparation transaction held while it executes | Explicit separation of encoding, Policy and save | F0/F3; application-defined side effects remain its responsibility | YES for the framework-owned transaction boundary |
| Confirmed records: restart readability and continuation | Existing Persistence and Recovery contracts | F4; replay or resolution depends on the external operation | CONDITIONAL, no broader resumption guarantee |
| Arbitrary external-effect exactly-once execution | No new external protocol or distributed exclusion | F1/F4 across X0 | NO new guarantee |

Existing causal-durability tests now invoke the owning worker instead of private
Coordinator persistence methods. Architecture guards inspect the complete worker,
including helpers, while keeping checks on EventLoop apply. Behavioral probes
exercise Policy outside transactions, post-Policy watermark/cancellation checks,
encoding-response loss, post-commit materialization failure, reconciliation read
failure, materialization failure after confirmation, and same-revision content
conflicts. Existing valid Agent/Tool execution, Recovery and Handoff suites cover
the production wiring. Public API, loading and gem-content checks remain required.

## Remaining work

Initial preparation, approval snapshot isolation, and normal/Handoff outcome
persistence are separate stages. The approval Hash/Mutex is not moved into this
worker. The existing Coordinator and Handoff terminal machinery are unchanged.
This stage improves responsibility and abstraction boundaries; it does not claim
to remove every Agent dependency cycle or finish Coordinator decomposition.
