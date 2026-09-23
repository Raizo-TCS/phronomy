# Remaining responsibility refactoring

This is an implementation plan, not a new Storage SPI or Workflow lifecycle
contract. The inventory baseline is core `e4ad9948798a4f165d052bd8ab5ac3574cf48e24`
and examples `2f8b467f1268dd21de4c02b1c90c8bdd211d1feb` on `refactor/architecture`.

W1 is now verified at core `42f61514929645662e16b571afff9f4060d867d1`.
W2a is applied and verified at core `01cd2f57549f6d1e60825254f4520d0f123e651c`.
W2b is implemented in Refactor 33; application verification remains. See the
[W2 design review](workflow-terminal-ownership-design.md) and
[ADR-056](../decisions/056-workflow-terminal-policy-ownership.md).

## Completed boundaries

ExecutionCoordinator's staged split, ToolInvocation restoration ownership and
SharedState's MultiAgent ownership are complete. Domain codecs/repositories
already belong to Agent, MultiAgent and Workflow (ADR-033). Raw storage conflicts
already use Storage-owned exceptions (ADR-043). `FSMProtocol::FINISH` already
owns the common terminal marker; that earlier constant dependency is not the
remaining Workflow problem.

## Execution order and completion gates

| Step | Remaining concern | Scope and completion gate |
|---|---|---|
| W1: Refactor 31 | Two terminal-save implementations, selected by prepend | Applied and verified. The active F1-aware implementation belongs to Runner and the override is removed. See [ADR-054](../decisions/054-workflow-terminal-save-single-owner.md). |
| W2a: Refactor 32 | Terminal observer exceptions leave stream and admission pending | Keep the error path open through notification, preserve the original exception and any confirmed save, and verify application before ownership extraction. See [ADR-055](../decisions/055-terminal-observer-failure-settlement.md). Applied and verified at 01cd2f57. |
| W2b: Workflow terminal ownership | FSMSession interprets `workflow_terminal_persistence_result` and success/known-failure/unknown outcomes | Implemented by WorkflowTerminalPolicy and FSMProtocol::TerminalDecision in Refactor 33; application verification remains. Preserve session identity, event acceptance, stream barriers, admission retention/release and Task ordering. Do not simply hide the same Workflow policy behind renamed Engine methods. |
| S1: Storage contract design | Eight fixed repository slots and Agent watermark are in the shared contract | Inventory atomic operations and physical implementations below, choose the smallest neutral contracts and domain-owned backend extensions, and verify F0/F1/F2 boundaries before changing SPI. |
| S2: Storage implementation and migration | Common/domain contracts and all backends must agree | Coordinate core, InMemory, SQLite and PostgreSQL changes in one reviewable migration. Preserve the transaction domain and record formats, prove rollback/constraints and document any intentional Beta SPI change. |
| S3: Naming and closure | Common framework naming and public Persistence facade can be conflated | Decide names after the contract is established. Keep the public Persistence facade unless an explicit public migration is justified. Verify application and remaining dependency directions; do not rename merely to simplify a diagram. |

W1 precedes W2 so the active terminal save is explicit before its session-facing
ownership changes. W2 can be completed without redesigning Storage's raw SPI.
Storage follows because its common contract affects all domain repositories and
both SQL reference implementations. Verify the applied commit before producing
the next dependent source package.

## W2 implemented boundary

Runner retains snapshot capture, Offload submission, one save and F1 readback.
WorkflowTerminalPolicy recognizes the Workflow result event and interprets its
outcomes. FSMSession receives only complete/fail/retire decisions and owns its
pending state; Registry remains the sole Workflow admission owner.

The private terminal_policy injection replaces terminal_barrier, without a
public plugin API or alias. Agent/Tool and ephemeral Workflow keep immediate
completion. Unknown outcomes retain admission and an unresolved caller until
normal shutdown clears admission; shutdown does not synthesize a caller result.
Refactor 32's observer-error ordering and committed snapshot are preserved.

The candidate tests delayed success, known failures, F1 reconciliation,
uncertainty/shutdown, early/duplicate/late events, ordinary events during the
barrier, observer errors, rejected submission/delivery and shared Agent/Tool
behavior. Verify application before proceeding to Storage S1-S3.

## Storage operation inventory

Removing Agent/Workflow constant references did not make the SPI domain-neutral.
`Storage::Backend < Storage::Repositories` still constructs eight required slots;
`assert_agent_watermark!` checks Agent revision and Journal position together.

| Current area | Existing constraint to preserve | Ownership/design question |
|---|---|---|
| Contents | Canonical content identity and reads/writes join the same transaction | Keep the content contract without coupling it to an execution owner. |
| Agents / Teams | Key identity and expected/next revision CAS | Separate physical compare-and-write from domain record validation. |
| Journals | Expected head position, append order and record identity | Preserve atomic append; a generic key/value write alone is insufficient. |
| Agent / Team executions | Atomic active-owner exclusion, immutable owner identity, revision checks and indexed queries | Decide a neutral constraint/index primitive or explicit domain-owned extension; never replace atomic admission with an unlocked preflight. |
| Workflow / Handoff states | Create/update/delete CAS and stored identity | Preserve nil pre-revision creation and conditional deletion, with domain interpretation above the raw contract. |
| Agent watermark | Revision and Journal head observed consistently with subsequent writes | Express a multi-record precondition or domain-owned transaction operation, not independent reads above the backend. |
| Transaction view | All eight repositories, content and watermark share one view | Keep InMemory's one Monitor/snapshot and each SQL view's one checked-out connection; splitting classes must not split commits. |
| Errors / capability declarations | Dedicated active constraint errors, ordinary conflicts and uncertainty remain distinct | Revisit domain terms in capabilities without adding stronger concurrency or commit-certainty promises. |

Reference implementations live in `storage/backends/in_memory.rb` and examples
`30_sqlite_persistence` / `31_postgresql_persistence`. Inspect SQL indexes, lock
order, connection binding and rollback as well as Ruby signatures. Storage's
existing Agent/Team implementations have different details; do not assume they
are interchangeable just because their method names resemble each other.

S1 must produce a mapping from every current operation to its owner and atomic
primitive, plus API/RBS migration and backend conformance gates. Do not adopt a
generic key/value API, callbacks inside transactions or a registry of arbitrary
operations merely to erase domain names. Keep record type/version/payload,
existing F0/F1/F4 limits and the X0 external-effect boundary explicit.

See the existing [persistence staged plan](persistence-refactoring-plan.md),
[ADR-033](../decisions/033-domain-persistence-ownership.md) and
[ADR-043](../decisions/043-storage-execution-constraint-notifications.md).
