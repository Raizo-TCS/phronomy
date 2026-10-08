# r8 unit 4: Agent execution and MultiAgent responsibility

Core baseline: `3c5fddcae31cc98f8e081feae9b955cf536e5834`.
Examples baseline: `0370d09fb1608b9596e1803275f713b1a204af26`.
The foundation mapping dated 2026-09-30 and its target/concept diagrams remain the
refactoring goal. This change implements the C01/C04 boundary; it does not claim
that the whole existing implementation already matches the target DAG.

| Responsibility | Owner and current entry point |
|---|---|
| Exact execution identity, admission and observation | Agent `ReservedExecution`, `start_reserved_async`, `resume_async`, `cancel_async`, `Store#observe_execution` |
| Finalized input, groups and provenance | Agent `ControlRequest`, `TransferContext`, `TransferProjection` with Context assembly |
| Selection policy, Source/Target mapping and routing | MultiAgent `HandoffPolicy`, capability binding, `HandoffRunner`, `HandoffParticipant` |
| Static subagent slot, definition, input, inherited knowledge and import progress | MultiAgent `DurableSubagentCoordinator`; immutable content snapshot |
| Execution/Root/journal mutation and publication authority | Agent `ExecutionChange` and `ExecutionOutcomeCommitter` |
| Whole-Agent retention and durable cancellation intent | Agent public operations; Agent-owned record resources |
| History removal and release of its own holds | MultiAgent `Store#forget_subagents`, `Store#forget_handoff` |
| Physical record adapters and schema | Each domain's Persistence implementation; composition assembles them |
| Offline old-format conversion | `PersistenceComposition::Unit4Migration`; examples SQL runner |

Agent interprets neither child states nor routing phases. MultiAgent uses public
Agent values and operations; it does not read AgentExecution, raw metadata,
journals, ContextImporter values or a private event-listener getter. Child results
are observed from their authoritative execution, never mirrored as mutable child
statuses in the parent snapshot. IDs for new slots are derived from canonical
parent Agent/execution/slot identity. Migration preserves existing IDs.

## Commit participant contract

A current, synchronous participant declares a `binding` key/version and implements
`commit`, `guard_change`, and `change_evidence`. `ExecutionChange` exposes semantic
inputs only. In one outer `Persistence#atomic` scope the participant:

1. Locks routing/Team guards where needed, then Agent roots in lexical ID order.
2. Calls `change.prepare_in(scope)` before its own writes. This captures complete
   pre-state, including cancellation intent, under those guards.
3. Changes its own records and calls `change.commit_in(scope, state:, transfer_receipt:, pending:)` once.
4. Returns after the outer commit. Agent publishes the captured result only then.

The change is bound to the original thread, coordinator and prepared scope. It
checks its Agent watermark and expected execution revision. A nested savepoint
cannot authorize publication. Reconciliation compares Root, execution payload,
appended journal, extension content, cancellation intent, and participant evidence
in a consistent scope. Exact post-state proves commit; exact pre-state proves no
commit; different state or failed reads require recovery. There is no write retry.
An updated record at the expected revision alone is insufficient evidence.

Subagent cancellation retains unresolved active work. Known business errors may
follow `on_error: :skip`; unknown external outcomes cannot be skipped into success.
Handoff Source transfer and Target terminal stabilization join the same Agent
change. A suspended or recovery-required Target does not stabilize routing.
Current participant key/version and Target definition must match before resuming.
Terminal results can still be read without re-creating application wiring.

## Retention and cancellation

`agent.retentions` prevents purge independently of MultiAgent schema. C01 records
its parent/child or conversation holds when reserving/creating work. History
removal checks unfinished work, removes its references and releases only its own
owner key in the same transaction. Other holds remain authoritative.
`agent.cancellations` stores monotonic intent separately from execution revision,
so an external cancel does not invalidate an in-flight worker's captured revision.
Signal delivery follows the durable write; restored executions read that intent.

`Agent::Admission` remains the same-scope acceptance boundary. A participant never
starts a child inside a transaction or waits for its lifetime on a worker thread.
Ordinary Agent composition does not load MultiAgent routing repositories.
Standalone `dispatch_parallel` keeps its existing Runtime-scoped behavior.

## Remaining boundaries

`MultiAgent::AdmissionRegistry` still uses Runtime shutdown coordination. Agent,
Tool and Workflow execution internals still depend on existing Engine mechanisms.
These are later r8 work, not erased by constructor injection or diagram grouping.
The measured source diagram includes those edges and cycles. PostgreSQL lock
ordering needs its actual database gate; SQLite/InMemory results do not establish
PostgreSQL behavior. The application package records executed and unexecuted gates.

See [API and saved-data migration](../migrations/r8-unit4.md).
