# Remaining responsibility refactoring

This tracks responsibility work, remaining proposals and acceptance gates; it does
not define a new Storage SPI or Workflow lifecycle contract. The historical
inventory baseline was core `e4ad9948798a4f165d052bd8ab5ac3574cf48e24`
and examples `2f8b467f1268dd21de4c02b1c90c8bdd211d1feb` on `refactor/architecture`.

W1 is now verified at core `42f61514929645662e16b571afff9f4060d867d1`.
W2a is applied and verified at core `01cd2f57549f6d1e60825254f4520d0f123e651c`.
W2b is applied and verified at core `fcd434c45ad98e5c93953cbce1ffef3c12246894`. See the
[W2 design review](workflow-terminal-ownership-design.md) and
[ADR-056](../decisions/056-workflow-terminal-policy-ownership.md).

The current applied baseline is core
`b3dfbc5a65daf3ac52a902c2f832ac4216978966` and examples
`68a0bbd0e354b9e00bbfed728ad2b769b389ed8a` (Refactor 40; examples unchanged).
S2b/S2c were verified on Refactor 35, including PostgreSQL CI against its
core ebd99623 / examples 68a0bbd0 pair.
Refactor 36's S3, Refactor 37's D02, Refactor 38's R03/R11, Refactor 39's R06
and Refactor 40's R07 are applied and verified. The diagram is on applied40-01.
Refactor 41 implements R08/D08; its application is not yet verified. See the
[closure review](refactoring-closure.md) for retained names, evidence and limits.

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
| W2b: Workflow terminal ownership | FSMSession interprets `workflow_terminal_persistence_result` and success/known-failure/unknown outcomes | Applied and verified in Refactor 33 at fcd434c4; WorkflowTerminalPolicy and FSMProtocol::TerminalDecision own the boundary. Preserve session identity, event acceptance, stream barriers, admission retention/release and Task ordering. Do not simply hide the same Workflow policy behind renamed Engine methods. |
| S1: Storage contract design | Eight fixed repository slots and Agent watermark are in the shared contract | Design completed: Records/Streams/Blobs with conditions and guarded checks. The existing 37 raw methods have been inventoried; S2b now implements that design. |
| S2a: Refactor 34 | Existing update, batch validation and nested transaction differences | Applied and verified at core ac07b6d4 / examples ae538996, including PostgreSQL 17.11 on Ruby 3.2/3.3/3.4. See ADR-057. |
| S2b: Neutral Storage SPI | Common/domain contracts and all backends must agree | Applied and verified at ebd99623 / 68a0bbd0: Records/Streams/Blobs, feature schemas/adapters, failed-view lifecycle and non-local-exit rollback. See ADR-058. |
| S2c: Integration and migration | Physical backends must satisfy the same contract | Completed for Refactor 35. PostgreSQL 17.11 on Ruby 3.2/3.3/3.4: 119 examples per version; SQLite: 116. All 13 CI jobs checked out the verified core/examples pair. API/RBS, gem, round-trip data compatibility and applied trees were verified. |
| S3: Naming and closure | Common framework naming and public Persistence facade can be conflated | Reviewed and implemented in Refactor 36: retain public Persistence, neutral Storage, feature schemas and separate composition; move resource-reference normalization from generic Validation to Resource. Update stale status documents. Applied and verified at d98822b3; do not rename merely to simplify a diagram. |

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
behavior. Its application verification is complete; Storage S1 design followed.

## S1 baseline operation inventory (before SPI 2)

Removing Agent/Workflow constant references did not make the SPI domain-neutral.
`Storage::Backend < Storage::Repositories` constructed eight required slots;
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

## S2a and S2b applied boundaries

[ADR-057](../decisions/057-storage-transaction-boundaries.md) records the three
behavioral changes. The [migration guide](../migrations/storage-transaction-boundaries.md)
explains nested savepoints and propagated ActiveRecord::Rollback. Complete batch
validation prevents invalid input from leaving partial Journal rows; it does not
make arbitrary database failures safe to catch inside the failed scope.

S2a alone did not complete Storage. Refactor 35 subsequently implemented the
neutral SPI, failed-view rules and non-local exits, then passed live PostgreSQL
acceptance against the applied core/examples pair. Reference SQL code parity
alone was not used as PostgreSQL execution evidence.

## Refactor 35 verification history

Core baseline: ac07b6d4b47167ae404c8ecad8450e80a0087754.
Examples baseline: ae538996fd276faa3dac0990839e9cf115e6dff6.
S2b changes the raw SPI and both SQL implementations together. Domain APIs and
stored formats remain. Candidate checks include InMemory, real SQLite, generic
resource declarations, scope failures and old/new/old SQLite data compatibility.
The applied pair above passed all three examples workflows, including
[PostgreSQL](https://github.com/Raizo-TCS/phronomy-examples/actions/runs/35827495677),
[SQLite](https://github.com/Raizo-TCS/phronomy-examples/actions/runs/35827495667) and
[current API](https://github.com/Raizo-TCS/phronomy-examples/actions/runs/35827495646).
Each job's checkout SHA was verified, not just its green status. Core remote
workflows had no runs; local core suites supplied that evidence.

## Closure boundary

W1, W2a, W2b, S1, S2a, S2b and S2c are applied and verified. S3's bounded Storage
cleanup and audit are applied and verified in Refactor 36.
The original review is not fully implemented: the W/S-only inventory omitted
D02, R03's metadata boundary, R06, R07, R08/D08, parts of R09, R10 and R11.
See the reconciled inventory below; do not count those proposals as completed.
Keep the published dependency SVG tied to applied40-01 until Refactor 41 application verification. Performance benchmarking, live-LLM behavior,
distributed ownership and unknown-outcome recovery policy are separate scopes,
not silently added requirements for this responsibility refactoring.

## Initial review proposals and current disposition

| Initial item | Current assessment and follow-up |
|---|---|
| D02 | Applied and verified in Refactor 37: callers construct OperationBinding directly and retain ordering and cancellation contracts. |
| R03 | Applied and verified in Refactor 38: ExecutionMetadata owns shared durable keys and snapshots; ToolInvocation owns stable identity. Earlier restoration behavior is preserved. |
| R06 | Applied and verified in Refactor 39: InvocationTransitions owns Tool events, ordered external transitions and state declarations for both builders and Invocation. |
| R07 | Applied and verified in Refactor 40: ContextAssembler describes preparation through private instruction, record-candidate, candidate-merge and current-input operations. |
| R08 / D08 | Refactor 41 candidate, one overlapping item: GeneratorVerifier keeps its facade and Result; private WorkflowBuilder, AgentResultReceiver and the moved PipelineState separate graph construction, reception and state. Application verification remains. |
| R09 | Partial: composition moved, but Base's Tool binding remains. DSL inheritance differences require a behavior decision before modification. |
| R10 | Unimplemented: filtering_input_action/building_context_action and Team's TaskResult wording still describe different responsibilities. |
| R11 | Applied and verified in Refactor 38: Values::Serializable owns recursive conversion. Caller-specific diagnostics and distinct immutable/canonical/codec contracts remain. |

R08/D08 is one work item. R03's Tool restoration and shared metadata ownership
are complete; do not reopen those contracts. R09's configuration inheritance can
change public behavior and needs its own explicit decision. These are existing
proposals rediscovered by the S3 audit, not new performance or distributed-runtime
requirements. D02, R03/R11, R06 and R07 are applied and verified. R08/D08 has a candidate.
After Refactor 41 application verification, proceed to R09;
coordinate R10 with its owners.


## D02: direct operation binding (Refactor 37, applied)

OperationBinding already owns invocation context validation, its private linked
cancellation token, deadline subscriptions and result-scoped cleanup. Its three
clients now construct it directly. Execution's pass-through factory has no
additional behavior and is removed without an alias or replacement factory.

Construction remains at the same points: Agent before command admission,
Blocking only with an explicit context and before Offload submission, and
Orchestrator for each child before invoke_async. Keep bind/track/close ordering,
error handling, context selection and cancellation ownership unchanged.
Orchestrator still uses Execution for fan-out/fan-in; that dependency is intended.
The internal OperationBinding signature and body, except its ownership comment,
are unchanged. No class, production file, public API or examples change is added.

The distribution is applied and verified at e7e66184. D02 is closed.
Seven initial-proposal groups remained at that point; R03/R11 are now applied below.


## R03/R11: shared execution metadata and conversion (Refactor 38, applied)

See [the ownership and compatibility design](execution-metadata-and-values.md).
ExecutionMetadata owns the shared keys, version, snapshot and merge.
ToolInvocation.semantic_id owns the stable Tool identity, while
Values::Serializable owns recursive Ruby-to-JSON-tree conversion.
RecoverySupport retains recovery interpretation; the existing conversion entry
points retain their distinct diagnostics. No new restoration, transaction or
external-operation behavior is introduced.

Refactor 38 is applied and independently verified at core 690b2823, tree
67ea6df833254341043c3fb1e99729d66f9598f6. All 30 full files and the tree match.
Core 2,970 (61 pending), integration 367 (28 pending), common examples 42 and
SQLite 116 passed with zero failures, as did API/RBS, style and gem checks.
R03/R11 are closed. Five groups remained at that point; R06 is now applied below.
The diagram was synchronized to applied38-01 then and is now applied40-01.


## R06: Agent transition ownership (Refactor 39, applied)

See [the transition ownership design](agent-transition-ownership.md).
InvocationTransitions owns the six Tool event names, thirteen external event
families and their ordered transitions, initial phase and state classifications.
PhaseMachineBuilder compiles the external transitions into state_machines;
AgentInvocationSessionBuilder passes the same definition to FSMSession.
AgentInvocation uses the Tool vocabulary to identify payloads it handles.

FSMSession still uses only source-state declarations to decide whether an
external event is accepted or a phase must wait. The machine evaluates guards
against the current context, after payload application. Engine does not acquire
Agent policy, and automatic transitions and entry actions keep their owners.
No new generic DSL, compatibility alias, public API or persistence format is added.
R10's entry-action names and R09's DSL inheritance semantics are separate work.

The implementation preserves callback-failure, Handoff-failure, Handoff-request,
Tool-request and output-fallback priority, nil-context fallback, guard exceptions,
approval suspension and resume. Independent behavioral expectations pass on both
baseline and candidate; full-suite results are in the distribution evidence.
Refactor 39 is applied and independently verified at core 4d57614a, tree
654241da4b2b7f32d988602d28127bc1fa155641. All 10 full files and the tree match.
Core 2,993 (61 pending), integration 367 (28 pending), common examples 42 and
SQLite 116 passed with zero failures, as did API/RBS, style and gem checks.
R06 is closed. Four groups remained then; R07 is now applied below.
The diagram was synchronized to applied39-01 then and is now applied40-01.


## R07: Context preparation steps (Refactor 40, applied)

See [the preparation design and compatibility boundaries](context-preparation-steps.md).
ContextAssembler retains its public preparation/finalization boundary and its
existing collaborators. Seven private operations separate initial/base/Handoff
instructions, retained instructions, record candidates, Hook/Handoff merging
and the current-input item. No production class or file is added.

The public prepare methods now describe the preparation steps; item IDs,
provenance and metadata live in the corresponding item-building operation.
Initial and follow-up paths share generation filtering and candidate merging,
while preserving their distinct instruction sources, exclusion rules, call
sequence and ask/complete delivery. Evaluation and content-store effects retain
their order. Application Policy remains outside the caller's commit transaction;
finalize remains validation and persistence, without a Policy call.

Ten additional contract examples pass against both Refactor 39 and the candidate.
Four paired initial/follow-up scenarios compare complete Policy input, Prepared,
Manifest references/bytes and content operations across separate processes.
Full core/integration/examples/API/type/package gates are in the distribution.

Refactor 40 is applied and independently verified at core b3dfbc5a, tree
dcd9d1bf8efb1b488f9c2b3b1c4e99bdeda6096c. All six files and the tree match.
Core 3,003 (61 pending), integration 367 (28 pending), common examples 42 and
SQLite 116 passed with zero failures, as did API/RBS, style, gem and four paired
preparation scenarios. R07 is closed. Three groups remain: R08/D08, R09 and R10.
The published diagram is applied40-01; keep it until Refactor 41 application checks.


## R08/D08: GeneratorVerifier ownership (Refactor 41 candidate)

See [the ownership and event-contract design](generator-verifier-ownership.md).
The public facade retains configuration, lazy Workflow caching, default parsers
and Result construction. Private WorkflowBuilder owns graph assembly, request
startup and convergence. Private AgentResultReceiver converts Agent terminal
events into correlated Workflow events. PipelineState moves without changing its
canonical name, fields, correlation checks or mutation behavior.

The three implementation files live below generation/generator_verifier. No
loader change or alias is needed. This updates the original D08 location sketch:
the pattern already has generation ownership, so it does not move to MultiAgent.
Draft/review payload meanings remain separate. Only their identical terminal
classification, completion-notification rescue and failure notification are shared.
The receiver holds no request-specific mutable state and never mutates Workflow
context; PipelineState still applies accepted results on the EventLoop.

Thirty-nine additional event-contract examples pass on both baseline and candidate,
including inline completion, failures, parser/notification exceptions, old and
duplicate results, normalization, convergence, caching and config forwarding.
The public signature/Result/state contract also matches. Full gates are recorded
in the distribution. Existing semantics remain: final trust is score-based, even
if an unapproved high-score draft is finalized at the iteration limit.

R08/D08 is application-pending. After its check, two groups remain: R09 and R10.
Keep R09's DSL inheritance behavior decision separate from internal extraction.
