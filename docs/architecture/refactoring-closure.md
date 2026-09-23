# Responsibility refactoring audit (S3)

## Scope and acceptance state

The applied baseline is Refactor 38: core
`690b28239a30129484388b16728a52746ce4a5de` and examples
`68a0bbd0e354b9e00bbfed728ad2b769b389ed8a` on `refactor/architecture`.
W1/W2, Storage S1/S2 and Refactor 36's S3 cleanup are applied and verified.
Refactor 37's D02 and Refactor 38's R03/R11 changes are applied and verified.
Refactor 39 implements R06 transition ownership; its application is not yet verified.

The S3 audit and its bounded Storage cleanup are verified. The initial review
still contains open proposals. The previous remaining-work summary omitted still
unimplemented work. The original R/D proposals must not be marked complete just
because the later W/S sequence has reached its final step.

## Names and locations retained

| Owner | Name and location | Reason |
|---|---|---|
| Application facade | `Phronomy::Persistence`, `persistence/api` | Users address domain repositories and queries. This class is not the neutral backend contract. |
| Domain persistence | Agent, MultiAgent and Workflow `persistence` directories | Codecs, durable meanings, result queries and business constraints belong to the feature. |
| Resource declarations | Agent persistence, Team/Workflow `storage_contract`, ContentStore | Schemas describe domain metadata; the nested roots keep existing Ruby identities without loading feature runtime just to obtain declarations. |
| Common storage | `Phronomy::Storage`, `storage` | Resource/Record/Stream/Blob, conditions and transactions describe backend-neutral mechanisms. |
| InMemory driver | `Storage::Backends::InMemory`, `storage/backends` | Implements physical operations over a supplied resource catalog. It does not choose domain schemas. |
| Repository assembly | `persistence_composition` | Gathers declarations and constructs the feature wrappers over one View. |
| SQL reference drivers | examples `shared/storage` and adapter entry points | SQL is a reference integration, not a core ActiveRecord dependency. Physical mapping is separate in `shared/persistence_storage_mapping.rb`. |
| Configuration and defaults | `configuration` / `runtime_composition` | Scalar settings and default factories do not own concrete Runtime/LLM/Tracing assembly. |

No facade rename, new generic dispatcher, compatibility alias or additional
ExecutionCoordinator split is needed to establish these boundaries.

## Resource-reference ownership

GuardRef and the three closed Condition values accept either a Resource object
or a textual resource ID. Resource owns this type-specific normalization in an
internal cooperation method. Validation retains scalar and immutable-value
operations. The dependency is Resource to Validation, with no reverse reference.

A Resource object is retained by identity; an ID is validated, copied and frozen.
There is no duck-typed coercion or conversion of a foreign schema object to an
ID. View continues to reject an unregistered object even if its ID matches.
The public constructor signatures, result values, exceptions, scope lifecycle,
SQL operations and stored formats are unchanged.

## Completed responsibility inventory

| Work | Current owner / evidence |
|---|---|
| Root layout and shared definitions | Eight direct-root namespace/version files; values and exceptions in common; entry-point loading and public identities guarded by source_layout_spec. |
| FSM terminal marker and live control | FSMProtocol/FSMSession in Engine; Workflow's result interpretation in WorkflowTerminalPolicy. |
| Workflow final save | One F1-aware implementation in WorkflowRunner; no WorkflowRecovery prepend override (W1/W2). |
| ExecutionCoordinator | EventLoop-side sequencing/acceptance; named preparation/persistence workers hold worker-side tasks. ToolInvocation owns its restoration sequence. |
| Multi-agent coordination | HandoffRunner and SharedState in MultiAgent; durable domain records retain their feature owners. |
| Public persistence queries | Agent/Team query traversal is separate from the public facade and repository assembly (D07). GeneratorVerifier is not counted as completed; see R08/D08 below. |
| Storage | Neutral SPI 2 and all three backends validated; domain conditions and physical operations have distinct owners. |
| Final naming and documents | Retained names above, Resource/Validation cleanup, current stage status and historical migration guides reconciled in Refactor 36. |

The exact implemented names supersede early alternative sketches. For example,
WorkflowRunner kept its canonical constant in a feature-owned loader root rather
than being renamed to a nested class. Closing a goal does not require adopting
every early filename suggestion.

## Initial-proposal reconciliation

The original review's R01/R02/R04/R05 and D01/D03-D07/D09 goals have current
implementations. R12 is the continuing test-review rule used when changing a
boundary, not a claim that all source-structure guards must disappear. A01's
shutdown boundary and the revised A02 removal are implemented.

The broader A proposals map to those same goals rather than adding another
independent set of tasks: A03 includes D02 (now verified) and the open D08 work;
A04's record/codec separation and neutral backend contract are implemented,
while composition review overlaps R09; A05 keeps the same public Tool Class and
places ToolExecutor beside the capability contract, preserving its documented
bridge to Engine; A06's execution/context separation is implemented but its
shared recovery metadata concern is now resolved by Refactor 38 under R03. No claim is made that all
Agent directory cycles disappeared.

The following initial items are still open or partial. They were omitted from
the recent W/S-only inventory; they are not regressions caused by Refactor 35.

| Initial item | Current assessment and follow-up |
|---|---|
| D02 | Applied and verified in Refactor 37: callers construct OperationBinding directly and retain ordering and cancellation contracts. |
| R03 | Applied and verified in Refactor 38: ExecutionMetadata owns shared durable keys and snapshots; ToolInvocation owns stable identity. Earlier restoration behavior is preserved. |
| R06 | Refactor 39 candidate: InvocationTransitions owns Tool events, ordered external transitions and state declarations for both builders and Invocation. Application verification remains. |
| R07 | Unimplemented: ContextAssembler's prepare methods still mix preparation steps with detailed item/provenance construction. |
| R08 / D08 | One overlapping item, not two: GeneratorVerifier still combines PipelineState, Workflow construction and result reception. |
| R09 | Partial: composition moved, but Base's Tool binding remains. DSL inheritance differences require a behavior decision before modification. |
| R10 | Unimplemented: filtering_input_action/building_context_action and Team's TaskResult wording still describe different responsibilities. |
| R11 | Applied and verified in Refactor 38: Values::Serializable owns recursive conversion. Caller-specific diagnostics and distinct immutable/canonical/codec contracts remain. |

These entries identify real remaining proposals, not automatic authorization for
public behavior changes. D02 and R03/R11 are applied and verified. Refactor 39
implements R06's transition authority. After its application check, address
R07/R08/R09's readability work; R10 can be coordinated with its owning changes.
Keep R09's DSL semantics separate.
A complete initial-review closure requires implementation and verification or an
explicit decision to defer each item. It cannot follow from this small package.

## Evidence and limits

Refactor 35 application checks matched both complete repository trees, 85 full
files and 25 deletions. Local suites: core 2,953 (61 pending), integration 367
(28 pending), common examples 42, SQLite 116; all failures zero. Do not count
pending as passed or sum overlapping suites.

All 13 examples CI jobs used that exact core/examples pair. PostgreSQL 17.11
passed 119 examples per Ruby version (3.2/3.3/3.4), plus fresh-pool reload.
SQLite passed 116 per version. API/RBS, gem loading and old/new SQLite data
compatibility were also verified. Core remote workflows had no runs.

Refactor 36's exact applied tree and all ten files matched its distribution.
Core/integration/common examples/SQLite, API/RBS and gem checks passed on the
applied source. The Resource/Validation two-file cycle is removed; the published
SVG was synchronized to applied36-01 then. Refactor 36 did not rerun live PostgreSQL, and the existing
examples CI used Refactor 35's core. Do not infer newer-core CI from those runs.
Refactor 37 was independently verified after application: all seven files and
the full tree matched, and local core/integration/examples/SQLite, API/RBS and
gem checks passed. Core CI had no runs. Live PostgreSQL was not rerun.

The existing directory cycles (8/6/3/2 members) and the other file cycles remain.
Static constant/require analysis does not resolve all dynamic collaboration.
No new promise is made about unknown commit outcomes, distributed Workflow
admission, exactly-once external effects, performance or live-LLM providers.
Those are separate design/validation scopes, not unfinished items silently
added to this refactoring plan.


## D02 follow-up, applied

The direct construction change removes Execution.__operation_binding and its
three caller detours. OperationBinding keeps validation, linked cancellation,
deadline handling and subscription cleanup. No new generic factory or public
entry point is introduced. The three clients retain their admission and cleanup
ordering, and Orchestrator keeps its actual fan-out/fan-in use of Execution.
D02 is applied and verified at e7e66184. Seven R groups remained at that point;
R03/R11 are now applied below.


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
R03/R11 are closed. Five groups remain: R06, R07, R08/D08, R09 and R10.
The applied diagram is applied38-01; keep it until Refactor 39 application checks.


## R06: Agent transition ownership (Refactor 39 candidate)

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

The candidate preserves callback-failure, Handoff-failure, Handoff-request,
Tool-request and output-fallback priority, nil-context fallback, guard exceptions,
approval suspension and resume. Independent behavioral expectations pass on both
baseline and candidate; full-suite results are in the distribution evidence.
R06 is application-pending. After its application check, four groups remain:
R07, R08/D08, R09 and R10. Proceed to R07's ContextAssembler readability work.
