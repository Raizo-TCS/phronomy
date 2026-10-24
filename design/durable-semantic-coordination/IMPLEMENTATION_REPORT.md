# Durable Semantic Coordination V2 revision 2 — Implementation report

> Runner namespace update (2026-09-18): this document preserves the V2
> implementation/migration record. The current Runner is
> `Phronomy::MultiAgent::HandoffRunner` under
> [ADR-034](../../decisions/034-handoff-runner-coordination-ownership.md).
> Handoff and HandoffPolicy remain in Agent at this stage.

Created: 2026-09-07. Design approved: 2026-09-06.
Baseline: `5472116cd99a63ec27875024c955ea82be612d6b`.
This is a new implementation of the approved ADR-029/030/031 and RC-01 through RC-05.
It does not use the old Complete Durability overlay, existing work ZIPs, or synthetic fan-out executions.

## Implementation scope

| Area | Implemented behavior |
|---|---|
| Persistence | Eight repositories in both root and transaction views; the three new records use current format `0.1`. Backend handles opaque DurableRecords and explicit identity/revision/index metadata |
| Handoff | Moved to the Agent-domain API. Source terminal state, Context, exact Target reservation, and responsibility transfer are persisted in one transaction. Target terminal state and routing stabilization also share one transaction |
| Orchestrator | Stores child ID/input/knowledge/config/outcome for static subagent Tools in the existing parent AgentExecution. Direct `dispatch_parallel`/`fan_out` calls do not create synthetic parents |
| Team | Persists TeamRoot/TeamExecution, tasks, worker slots, and exact assignments/outcomes using CAS. Coordinators/workers use the existing Agent engine. Scheduling retains the existing sequential approach |
| Internal Team operations | Applies persisted authorized Tool batches in Provider order. Retains the result of each `tool_invocation_id` and automatically reconciles `enqueue_task`/`finalize` |
| Aggregate | Pure/replay-safe computation. Commits canonical JSON results or errors as terminal outcomes. Recalculation is possible after a crash before persistence, but not for a persisted terminal outcome |
| Runtime | Adds process-local Team ownership, admission, and draining. Does not add a new Team FSM/Workflow engine |
| Recovery | Resumes framework-owned operations from exact facts. In batches mixed with external Tools, only external facts are resolved through the existing Recovery API |
| Termination and deletion | Retains cancellation/reconciliation information for exact children. `purge!` on an idle main Agent also deletes the Handoff anchor; deleting an anchor for an incomplete turn is rejected |

A Handoff graph uses the same Persistence **instance**. The original main Agent ID is the routing anchor.
Persisted Context is not reprojected using a new policy, and persisted worker assignments are not reselected using the current scheduler.
Runtime Classes/Procs, listeners, Tasks, and CancellationTokens are not persisted.

## Public entry points

| Purpose | API / return value |
|---|---|
| Agent result access | `store.execution_result(execution_id)`; a frozen Hash containing owner, status, phase, result/error, and reference IDs |
| Handoff result access | `store.handoff_result(source_execution_id)`; follows the exact Target of that turn. No graph/Agent hydration is required |
| Agent execution discovery | `store.list_executions(agent_id, after: nil, limit: 100)`; immutable execution records, both active and terminal |
| Team result access | `store.team_execution_result(run_id)` or `team.result(run_id)` |
| Team execution discovery | `store.list_team_executions(team_id, after: nil, limit: 100)` or `team.executions(...)` |
| Handoff execution/recovery | `Agent::HandoffRunner.new(main_agent:, handoffs:).invoke(input, config: {})`; uses the persisted reservation and input if an incomplete turn exists |
| Static child recovery | `Orchestrator#resume(execution_id, config: {})` |
| Team creation/recovery | `team_definition id:, version:`, `create(team_id:, persistence:)`, `load(team_id, persistence:, on_event:)`, `resume(run_id)` |
| Explicit cancellation | `team.cancel(run_id)` / `handoff_runner.cancel(execution_id)`; existing Agent operations, including Orchestrator, use `config[:cancellation_token]` |

Lists are ordered lexicographically by semantic ID; `after` is an exclusive ID cursor, and `limit` is a positive integer.
This does not imply chronological ordering or unique correspondence to a request. Applications match candidates against their own correlation information.

Agent result status uses existing Symbols; Team result status uses canonical Strings.
The default Team aggregate result is also canonical JSON: Hash keys are Strings, and errors are data such as
`class`/`message`, not exception objects. Top-level assignment keys and task keys passed to aggregate are Symbols.

An unstarted Handoff Target reservation is identified by `status: :active, phase: :target_pending, reserved: true`.
Explicit cancellation of an unstarted Target preserves its reserved ID; a later turn never substitutes for the result of an earlier turn.
Absence produces `Persistence::NotFoundError`; read/decode failures produce their actual errors.
No facility to restore deleted results or retain them indefinitely has been added.

`Team.load` hydrates Team facts only. Child execution/recovery starts through `resume`.
Agent `load` retains its existing Recovery contract. Use the Persistence access APIs above when only results are needed.
Team's `on_event` is passed to hidden Agents to receive required Recovery/approval events.
`Team.stream` provides Runtime notifications of committed assignments; it adds no notification-delivery guarantee.

## RC mapping

Paths are relative to the repository root. The shared additional fault specs are in
`spec/phronomy/multi_agent/durable_coordination_spec.rb`.

| Requirement | Main implementation | Validation evidence |
|---|---|---|
| RC-01-A/B | `Persistence#execution_result` / `list_executions`, and corresponding Team APIs | Reads active/terminal candidates, pagination, and results in a reconstructed environment without loading the owner; does not invoke Providers or add ownership registrations |
| RC-01-C | `Persistence#handoff_result`, read-only materialization | Reservation access without graph/owner, read failures, and NotFound for purged results. Callback policy is also covered by the existing `stream_callback_error_policy_spec.rb` |
| RC-02-A | Existing F1 readback during Agent preparation, `reconcile_terminal_error`, Team `admit`/`update` | Lost acknowledgements immediately after each Team revision commit and Source transfer; reuse of committed worker/child outcomes |
| RC-02-B/C | Exact reservation reconciliation, atomic admission/CAS, bounded readback | Distinguishes read failure from absence. No dispatch after a failed readback following Team admission. Backend contracts check stale CAS, duplicate active records, and rollback across eight repositories |
| RC-03-A | Team definition snapshots, static child slot definitions, Handoff graph/Target matching | Fails closed on worker-version mismatch or missing Target/graph. Existing Handoff integration specs reject a different Persistence instance |
| RC-03-B | Immutable Context/input/knowledge/assignment/outcome | Uses persisted HandoffContext even when the current policy changes. Preserves worker results, static child results, and knowledge metadata |
| RC-04-A | Existing Task waiting/Runtime shutdown contracts | `task_spec.rb`, `agent/acs16_task_quiescence_spec.rb`, and Runtime/admission specs. Runtime reconstruction tests introduce no implicit cancellation |
| RC-04-B/C/D | Team cancellation flags, exact Handoff cancellation, Agent child-admission conditions, existing terminal barriers | Preserves reserved worker/Target IDs without starting them. A parent with an active child awaiting external facts remains active, persists cancellation information, and retains it after restart. Checked together with existing admission/physical-quiescence specs |
| RC-04-E | Source terminal link and Target cancellation; responsibility remains with Target | Cancellation after transfer, restart, and a later turn do not return responsibility to Source; historical reserved IDs and cancellation results are preserved |
| RC-05 | Separation of callbacks/external effects from semantic records | Mixed external/framework Tool batches resolve only external facts and do not rerun completed children. Application is not asked to determine facts about internal `finalize` |

The new shared examples in `lib/phronomy/testing/persistence_contract/coordination_repositories.rb`
run through `phronomy/testing/persistence_contract`, which is also exposed to external backends.
Existing guards for raw SPI/API snapshots/RBS, removal of old Handoff constants, the EventLoop single writer/causal barrier,
and logical-operation tracing are preserved.

## Validation scope and limitations

The measured environment is Ruby 3.3.6. Gem versions are recorded in the distribution ZIP's `verification/gems.txt`.
See the accompanying verification records for commands, results, and logs measured against the distributed files.

- Ordinary RSpec runs exclude integration tags requiring connections to external LLMs.
- Selected Handoff/Orchestrator/Team integration tests run with WebMock.
- Added F4 tests model recovery by copying committed DurableRecords and using a new Backend and Runtime.
  They do not demonstrate forced termination of a real OS process or fsync to physical storage.
- Separate suites using live LLMs, Redis, PostgreSQL, OpenTelemetry, and similar dependencies are outside this measurement.
  There are 61 pending cases: 59 with optional dependencies/services unconfigured and two existing obsolete cases.
- F4 durability and exclusion across multiple processes for external backends depend on the backend and deployment contracts.
  InMemory itself does not guarantee persistence after process termination.
- Semantic cancellation does not roll back external effects. Token objects are Runtime-only.
  Committed durable cancellation flags/facts are retained, and uncertain external operations are reconciled through existing Recovery.
  Waiting for facts/approval is not converted into failure that forgets a child; control returns through `ExecutionRehydrationRequiredError`.

The framework reuses committed outcomes and recovers incomplete executions with the same semantic identity.
It adds no callback outbox/ACK, global generic class registry, Proc/Class persistence, distributed transaction,
or second execution engine dedicated to Team.

## Package

The package includes complete files and a deletion manifest. Application checks the baseline and pre/post-application hashes.
New Class locations follow Zeitwerk naming conventions; the old overlay's decorator ignore is unnecessary.
The old `MultiAgent::Handoff*`, `Runner`, `Coordinator`, and `CoordinationState` implementations are removed.
See `README_APPLY_JA.md` at the distribution root for application, dependencies, and VERIFY procedures.
