# V2 Recovery Contract Clarifications - Approved Addendum

Updated: 2026-09-06 / Document revision: V2 revision 2

## 0. Purpose and authority

This addendum is a normative implementation contract reflecting the user's approval of five additions to V2.
Apply it together with ADR-029/030/031 and Implementation Design V2.
It preserves the original V2 responsibility boundaries while clarifying result access, unknown persistence outcomes, wiring compatibility, cancellation, and guarantee wording.
Where an earlier statement on the same issue differs, these clarifications take precedence. They do not otherwise replace existing ADR contracts.

The baseline remains `5472116cd99a63ec27875024c955ea82be612d6b`.
This is specification approval, not evidence of implementation completion or successful tests.
Public method names, exception names, and mappings to the existing cancellation implementation will be finalized after inspecting the baseline.
Requirement IDs in this document are for traceability; they are not new Runtime IDs, persistent IDs, or APIs.

## 1. RC-01: Accessing final results and discovering executions

### Required contract

- Application can obtain the owner identity, execution state, and committed result or error by semantic execution ID through read-only access.
- This covers AgentExecution and TeamExecution. Handoff/Orchestrator use existing routing anchors, parent executions, and reserved child/Target IDs; they do not create a new execution entity just for result access.
- Handoff identifies the Target outcome associated with the specified execution. The latest active Agent result from a later turn must not substitute for an earlier invocation's result.
- Provide a public path to discover execution candidates from a known agent_id/team_id, covering an interruption after admission commits but before Application receives the execution ID. Include terminal as well as active executions.
- Result access and candidate enumeration must not invoke Providers/Tools, continue Agent execution, redeliver callbacks, or acquire ownership. Distinguish these operations from operations that initiate recovery.
- Distinguish an unresolved result, absence, and inability to read. Do not translate Persistence failures or result-materialization failures into no execution, in progress, or successful completion without a result.
- Read basic state and committed results from persisted records. Do not require the graph/Procs needed for continuation merely to access results. Preserve existing codec/schema compatibility requirements.

### Scope limitations

Candidate discovery does not guarantee automatic unique correspondence to an Application request or exactly-once submission.
When multiple candidates exist, do not select one merely because it has the latest timestamp; Application must match its own correlation information.
Application-specific request IDs, outboxes, and deduplication remain Application responsibilities. Do not add generic idempotency infrastructure solely to meet result-access requirements.

Preserve existing retention/deletion contracts. Restoring deleted results, indefinite retention, and a new history-management service are not required.
Inspect existing API/SPI behavior and map list scope, ordering, pagination, and similar concerns to the smallest necessary public path.
Add only capabilities that existing APIs cannot provide; do not expose internal repositories directly as the public contract.

## 2. RC-02: Distinguishing absence, conflicts, and unknown persistence outcomes

### Shared decision rules

| Observation | Permitted decision or action |
|---|---|
| A successful authoritative read confirms that the reserved ID is absent | Check the parent's latest state, reservation, and cancellation conditions, then attempt admission with the same reserved ID |
| The exact ID is confirmed nonterminal | Follow the existing Recovery contract for the same execution |
| The exact ID is confirmed terminal | Use the persisted outcome; do not create a replacement execution |
| Read timeout / I/O failure / record decode failure | Preserve state and follow existing error/retry contracts; do not treat the failure as absence |
| Commit outcome is unknown, for example after a lost write acknowledgement | Retain the same operation identity and reserved ID for readback; do not create another ID or assignment before confirmation |
| A definite revision/admission conflict | Reread the latest authoritative facts and validate consistency with the reservation, owner, and input; do not treat the conflict as success by itself |

Readback consistency must satisfy the existing Persistence contract that protects admission/CAS.
Cache/index discrepancies and read failures must not justify new admission.
Use existing atomic admission/CAS to prevent races between confirming absence and admission.
Start external semantic work only after admission success is confirmed.

Scope: Source Handoff transfer, Target admission/stabilization, parent child reservation/outcome,
and Team admission/enqueue/finalize/assignment/worker outcome/terminal state.
Team-owned enqueue/finalize retain the existing policy of fact reconciliation using a stable tool_invocation_id.

While an unknown outcome remains unresolved, do not advance to the next semantic operation based on unconfirmed local assumptions.
Return control through existing Persistence error/retry paths instead of waiting synchronously without a bound.
Do not add manual resolution that requires Application to invent storage facts.
Reuse existing Agent/Persistence handling of unknown outcomes; do not create a second transaction engine dedicated to coordination.

## 3. RC-03: Minimum wiring compatibility for recovery

### Required checks

| Subject | Checks required before continuation |
|---|---|
| Agent/Team definition | Compare the persisted definition id/version with the current definition; require equality unless an existing explicit compatibility/migration contract permits otherwise |
| Orchestrator child | Match the persisted slot, the definition resolved from static subagent registration, reserved agent_id/execution_id, and owner |
| Handoff | Match the original main anchor, persisted active/Target IDs, required graph connections, and the same Persistence instance/domain |
| Team worker/coordinator | Match Team lineage, the persisted worker slot and definition, reserved Agent/execution IDs, and the persisted assignment |

If a required registration or Target is missing, a definition is incompatible, or the Persistence boundary differs, fail closed without starting semantic work.
Use existing configuration/rehydration error contracts and make the affected identity and type of missing/inconsistent information clear from the error.
Do not require execution wiring unnecessary for read-only result access (RC-01).

### Committed facts take precedence

- Do not reproject committed HandoffContext using the current HandoffPolicy.
- Do not replace committed child input/config with current defaults.
- Do not reselect committed assignments using the current scheduler.
- Do not recompute committed child/worker/final aggregate outcomes.
- Uncommitted scheduler/aggregate computations may rerun under the existing V2 replay-safe contract. Application must preserve semantic compatibility with the persisted inputs.

Phronomy can check declared identity/version and structure, not semantic equivalence of Ruby code.
Application is responsible for not introducing incompatible implementations under an unchanged version.
Increasing a version alone does not automatically enable recovery of old executions; the corresponding definition or an existing explicit migration contract is required.
Do not add Proc/Class persistence, source hashes, policy descriptors, or a global generic class registry.

## 4. RC-04: Ending observation and semantic cancellation

### Distinguish operations

| Operation or state | Contract |
|---|---|
| Application stops waiting, a connection is lost, or observation times out | This alone is not semantic cancellation of the durable execution |
| Runtime shutdown / process loss | This alone does not establish semantic cancellation; preserve execution and recoverability under existing shutdown/draining contracts |
| Explicit semantic cancellation request | Map it to the target owner/run and reserved executions under the existing Agent cancellation contract |
| Waiting for recovery resolution / approval | Preserve existing V2 rehydration paths; do not convert waiting into failure or automatic cancellation |

APIs that already request semantic cancellation, such as explicit cancellation of an existing Task, retain that contract.
Do not treat them as equivalent to merely ending observation. Record concrete public API mappings when inspecting the baseline.

### Applying cancellation to child executions

| Child state | Behavior after semantic cancellation of the parent run is accepted |
|---|---|
| Reserved, not started | Stop new dispatch owned by the current parent run; retain reservation information and do not start a child just to cancel it |
| Running, or racing with admission | Check the exact reserved ID's state and apply existing Agent cancellation; discarding a local Task alone does not complete cancellation handling |
| Terminal | Preserve the durable outcome; do not rewrite historical success/failure as cancellation or rerun it for compensation |

Handle races between parent cancellation and child admission using the latest parent-run state and existing admission contracts.
Reconcile an already admitted child under the running-child rules; do not create a child with a different ID.
Map the ordering of parent terminalization and child settlement to existing Agent cancellation/terminal-barrier contracts.
If a child is incomplete, retain its exact ID and required cancellation/reconciliation state.
Require rediscovery through existing recovery paths after restart; do not claim that all parent work is complete while forgetting an unhandled child.
Do not add a new public terminal status or a separate cancellation scheduler solely for this addendum.

Limit cancellation to children owned by the affected parent run; it must not affect other executions of a shared Agent or later Team runs.
A Handoff Source is handed_off after transfer commits. Cancelling Source later must not be treated as reversing the transfer.
Map explicit cancellation of the current Handoff turn to the relevant Target execution using persisted routing/reservations.
Do not return active responsibility to the original main Agent because observation ends or cancellation occurs.

Cancellation of external Providers/Tools does not guarantee reversal of side effects. Resolve uncertain outcomes through the existing Agent Recovery contract.
If existing mechanisms cannot satisfy the required ordering and rediscovery without a second execution engine or similar addition, report a Stop Condition.

## 5. RC-05: Consistent durability guarantee wording

> Reuse committed durable outcomes. Recover incomplete executions with the same semantic identity.
> Resolve uncertain outcomes of external Provider/Tool operations under the existing Agent Recovery contract.

Starting only when execution is confirmed not to have started refers to framework-owned execution admission.
It does not mean that no request ever reached an external system, nor does it guarantee exactly-once external side effects.
Recovering an incomplete execution with the same ID also does not mean unconditionally resending every internal Provider/Tool call.
Loss of a callback or local Task, or an observation timeout, must not justify rerunning semantic work.

## 6. Validation conditions and implementation mapping

The following are behavioral validation conditions, not a required count of new spec files.
Where existing specs verify a contract, record that evidence and add only missing cases.

| ID | Validation scenario | Required outcome |
|---|---|---|
| RC-01-A | Process loss after terminal commit and before callback | Read the same result by exact ID without rerunning semantic work or callbacks |
| RC-01-B | Caller is lost before the admission acknowledgement; execution later becomes terminal | Discover candidates from owner identity; do not arbitrarily choose one when multiple candidates exist |
| RC-01-C | Access results without a graph/listener, or inject result read/decode failure | Require no unnecessary wiring; do not disguise an access failure as success or absence |
| RC-02-A | Lose the acknowledgement immediately after each successful semantic commit | Adopt the existing fact through readback; create neither another ID nor duplicate assignments |
| RC-02-B | Independently inject read failure, authoritative absence, and CAS conflict | Keep the states distinct; execute only after admission success is confirmed |
| RC-02-C | Readback also fails after an unknown outcome | Preserve state and return control; do not wait synchronously without a bound or create a new execution |
| RC-03-A | Remove subagent registration, mismatch definition version, or omit Target | Fail closed before continuation; do not substitute another definition or Target |
| RC-03-B | Recover with compatible current wiring | Do not recompute committed Context/input/assignment/outcome |
| RC-04-A | End waiting, shut down Runtime, or lose the process | Do not establish implicit semantic cancellation |
| RC-04-B | Parent cancellation with an unstarted/active/terminal child | Follow state-specific rules and preserve exact IDs and committed outcomes |
| RC-04-C | Race parent cancellation against child admission/terminal state | Do not lose the child; remain consistent with existing cancellation/terminal barriers |
| RC-04-D | Lose the process at each commit boundary after a cancellation request | Rediscover and reconcile incomplete children of the same run through recovery paths |
| RC-04-E | End observation or explicitly cancel after Handoff transfer | Do not roll responsibility back to Source; apply cancellation only to the relevant Target execution |
| RC-05-A | Independently inject an uncertain external Tool effect and a lost callback | Use existing Recovery for the former and committed-result access for the latter; never rerun blindly |

When integrating with the baseline, record the public API/SPI, implementation locations, and existing/additional specs for each RC ID in a mapping table.
In particular, do not mark result-discovery APIs, compatible-version handling, or cancellation/terminal barriers complete using unverified method names.
Successful focused, backend, fault, and full-suite runs require actual measurement on the target checkout.
They have not been run at the time of this document revision.

## 7. Responsibilities that remain out of scope

Callback outbox/ACK, a terminal-delivery index, synthetic executions for standalone fan-out,
Proc/Class serialization, a global generic registry, distributed transactions across independent Persistence instances,
and a second execution engine dedicated to Team remain out of scope.
Public result access does not replace Application notification delivery or deduplication of external effects.

## 8. Implementation mapping

See [IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md) for the implementation, public API/SPI, and validation scope as of 2026-09-07.
The responsibility boundaries and required contracts in this addendum remain unchanged.
