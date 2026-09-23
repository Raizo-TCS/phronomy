# Responsibility refactoring audit (S3)

## Scope and acceptance state

The applied baseline is Refactor 36: core
`d98822b3b4d04f01d8b5303545747517ae49fb76` and examples
`68a0bbd0e354b9e00bbfed728ad2b769b389ed8a` on `refactor/architecture`.
W1/W2, Storage S1/S2 and Refactor 36's S3 cleanup are applied and verified.
Refactor 37 implements the rediscovered D02 proposal as a separate candidate;
its application still needs verification.

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
independent set of tasks: A03 includes the still-open D02/D08 ownership work;
A04's record/codec separation and neutral backend contract are implemented,
while composition review overlaps R09; A05 keeps the same public Tool Class and
places ToolExecutor beside the capability contract, preserving its documented
bridge to Engine; A06's execution/context separation is implemented but its
shared recovery metadata concern remains under R03. No claim is made that all
Agent directory cycles disappeared.

The following initial items are still open or partial. They were omitted from
the recent W/S-only inventory; they are not regressions caused by Refactor 35.

| Initial item | Current assessment and follow-up |
|---|---|
| D02 | Refactor 37 candidate: Agent, Blocking and Orchestrator construct Concurrency::OperationBinding directly; the Execution wrapper is removed. Application verification remains. |
| R03 | Partial: ToolInvocation owns restoration, but ordinary AgentInvocation still reads RecoverySupport's pending-LLM metadata key. Review the shared metadata owner. |
| R06 | Unimplemented: Tool event vocabulary and LLM transition guard order remain duplicated across Invocation and both builders. |
| R07 | Unimplemented: ContextAssembler's prepare methods still mix preparation steps with detailed item/provenance construction. |
| R08 / D08 | One overlapping item, not two: GeneratorVerifier still combines PipelineState, Workflow construction and result reception. |
| R09 | Partial: composition moved, but Base's Tool binding remains. DSL inheritance differences require a behavior decision before modification. |
| R10 | Unimplemented: filtering_input_action/building_context_action and Team's TaskResult wording still describe different responsibilities. |
| R11 | Partial: RuntimeRecordEncoder exists, but its json_value and RecoverySupport.canonical_copy still duplicate recursive conversion. Preserve their error contracts when reviewing consolidation. |

These entries identify real remaining proposals, not automatic authorization for
public behavior changes. Refactor 37 implements the small, previously delivered D02 on the current base.
After its application check, address R03/R11's shared vocabulary
and R06's transition authority before the larger R07/R08/R09 readability work;
R10 can be coordinated with its owning changes. Keep R09's DSL semantics separate.
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
SVG is applied36-01. Refactor 36 did not rerun live PostgreSQL, and the existing
examples CI used Refactor 35's core. Do not infer newer-core CI from those runs.
Refactor 37 must be verified as its own candidate and after application.

The existing directory cycles (8/6/3/2 members) and the other file cycles remain.
Static constant/require analysis does not resolve all dynamic collaboration.
No new promise is made about unknown commit outcomes, distributed Workflow
admission, exactly-once external effects, performance or live-LLM providers.
Those are separate design/validation scopes, not unfinished items silently
added to this refactoring plan.


## D02 follow-up candidate

The direct construction change removes Execution.__operation_binding and its
three caller detours. OperationBinding keeps validation, linked cancellation,
deadline handling and subscription cleanup. No new generic factory or public
entry point is introduced. The three clients retain their admission and cleanup
ordering, and Orchestrator keeps its actual fan-out/fan-in use of Execution.
This closes the source change for D02 only; application verification is pending.
The other seven R groups remain open or partial.
