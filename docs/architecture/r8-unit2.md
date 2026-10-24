# r8 unit 2: Parent reservation checks and Agent admission

This unit implements the P02/P03 admission boundary. The core baseline is `16e6fcb2dd49836735598525114abfc256d0773e`. It does not complete all of r8 or the entire Persistence reorganization.

## Responsibilities and operations

| Owner | Public operations and shared rules | Dependencies and internal implementation |
|---|---|---|
| Shared Persistence | `atomic`, `Transaction#participate`, and `committed?`; validates the same Persistence instance, synchronous thread, active scope, savepoints, and commit acknowledgements | Uses Storage's public transaction/scope rules; does not select Agent, Team, Workflow, or composition components |
| Agent | `Admission#accept_in`; persists input records, execution identity, Agent admission, and revision updates in the same scope | Uses Agent's persistence component; does not interpret parent kind, Team assignments, subagent snapshots, or Handoff reservations |
| MultiAgent | `ReservedChildAdmission#admit`; validates parent cancellation, slot, and child ID, and has Agent admission participate in the same scope | Its own persistence component reads the reservation evidence and acquires the required guards |
| Persistence components | `Agent::Persistence::Admission`, `MultiAgent::Persistence::Reservation` | Uses raw Storage views at this boundary; does not pass raw views to domain operations |

The existing ExecutionCoordinator continues to own acquiring Agent Runtime admission, starting the FSM, and applying live state. The new Admission covers only the short persistence phase; it does not place the entire Agent execution inside the parent's database transaction. Ordinary applications do not need to implement or instantiate the new participation classes.

`phronomy_admission` is current internal wiring; no Proc or object is persisted. Only the existing correlation information and parent/child IDs are stored. The Team/subagent/Handoff start and resume components supply the current participant. Reconnecting to a persisted execution preserves ExactExecution's same-ID matching and recovery rules.

## Persistence ordering and failures

1. Agent acquires the existing Runtime admission and begins the persistence operation on a synchronous worker.
2. MultiAgent opens a short `atomic` scope, acquires the parent guard, and then rereads the reservation.
3. It validates parent cancellation, assignment, and child identity. Agent stores the input content, AgentExecution, and AgentRoot in the same scope.
4. Only after a successful commit acknowledgement does the Agent execution component obtain the admission result and continue preparation, FSM execution, and live-state updates.

A participation operation's return value does not mean that commit succeeded. `accept_in` returns nil, and the Agent-internal `result` is unavailable until the outer commit. Duplicate participation, a different Persistence instance, a different thread, or an expired scope is rejected. Separate Persistence instances wrapping the same backend are not treated as the same scope. Code inside a raw backend transaction cannot claim to be a new commit owner.

Explicit nesting uses savepoints. Inner success is not committed if the outer transaction rolls back. Even if an exception during participation is caught inside the scope, earlier changes in that failed scope cannot be committed. Do not perform LLM calls, Tool calls, scheduling, external callbacks, or asynchronous waits inside participation operations.

Storage scope violations are translated into `Persistence::TransactionError`, preserving cause and backtrace. This naming change does not assert that the persistence outcome is known. Persistence failures with unknown outcomes, such as IOError, are neither translated nor automatically retried; they pass to existing Agent recovery rules. This unit does not add a generalized persistence-outcome reconciliation API.

## Races with cancellation

Team uses TeamRoot as its guard, subagents use the parent AgentRoot, and Handoff uses the routing record. On PostgreSQL, row locks on the guard and existing conditional updates order cancellation/changes against child admission. Ordinary reads on the child admission path alone did not provide this guarantee.

The Handoff cancellation path first observes the child state. If the child is incomplete or absent, it locks routing and **reads the child state again**. If child admission committed while it was waiting, it discards the stale absence observation and sends public cancellation to the admitted child. Cancellation of an already terminal execution continues to act as result access.

InMemory uses a shared Monitor, SQLite uses transactions and write-conflict detection, and PostgreSQL uses row locks. A conflicting SQLite transaction is not considered successful; its backend failure is handled. No distributed lease or exactly-once guarantee for external effects is added. Actual PostgreSQL waiting order is to be checked by the three new concurrency tests in examples; it must not be inferred from successful InMemory/SQLite tests.

## API and file changes

- Remove Agent::InitialPreparation's `build_admitted_execution`, its three kinds of parent validation, and its parent-kind branches. Separate shared Agent admission handling from MultiAgent reservation decisions.
- Place the shared participation framework in `persistence/transaction.rb`, Agent admission in `agent/admission.rb`, and persistence bindings in each domain's existing `persistence/`. No new directory or independent Contract is added.
- Add synchronous-context `transaction_open?` to the Storage SPI. Implementations inheriting Storage::Backend receive a shared implementation. Custom SPI implementations that do not inherit it must also provide this operation. Update RBS, the SPI snapshot, and duck-typed backend validation.
- Unify the public type for known Persistence scope failures as `Persistence::TransactionError`; do not add an alias for the old Storage exception. Code using Storage directly continues to use the existing Storage exception.
- Place RBS in sig and declare participant factories, Agent admission, and MultiAgent dependencies. Track dynamic `phronomy_admission` injection in this document and at its use sites.
- Separate dependency analysis rules for the Execution boundary from the diagram's revision display name. Add a regression test ensuring that changing the unit name does not disable the prohibition on synchronous-backend dependencies on Execution.
- Preserve persisted record formats, IDs, and revision rules. No data migration is required.

## Outstanding work

`Persistence#transaction` and the combined domain-repository facade still have callers and are not fully removed in this unit. This does not add new aliases for old names to preserve compatibility, but the P01/DP04 completion conditions remain unmet. Next, move domain queries and persistence composition, then remove unnecessary entry points together with their callers.

MultiAgent's persistence component still references Agent execution/Handoff repositories. Ownership of reservation validation has been clarified, but this does not mean that public parent/child projections, authorization queries, and result incorporation have all been encapsulated. Under the remaining P04/F02/F03 work, establish the operations Agent should expose and the persistence formats MultiAgent should own. Adding a generic metadata getter alone is not a solution.

Agent/Team FSM bindings, durable Workflow child coordination (P05), reconciliation of persistence outcomes across multiple records (P06), the remaining layout reorganization, and semantic reassessment of 155 pairs/393 cases also remain outstanding. The SVG for this unit depicts the implementation candidate, not a conceptual graph claiming that all cycles have been eliminated.
