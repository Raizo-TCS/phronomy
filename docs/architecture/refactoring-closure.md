# Responsibility refactoring audit (S3)

## Scope and acceptance state

The applied baseline is Refactor 42: core
`4a57a3c2574e2159a47291d202b7443aef4f8c25` and examples
`68a0bbd0e354b9e00bbfed728ad2b769b389ed8a` on `refactor/architecture`.
W1/W2, Storage S1/S2 and Refactor 36's S3 cleanup are applied and verified.
Refactor 37's D02, Refactor 38's R03/R11, Refactor 39's R06 and Refactor 40's R07
changes are applied and verified. Refactor 41's R08/D08 is applied and verified. Refactor 42 Tool binding and declaration rules are applied and verified.
Refactor 43 implements the remaining Chat/state ownership; application
verification is pending. R10 remains open.

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
| Public persistence queries | Agent/Team query traversal is separate from the public facade and repository assembly (D07). GeneratorVerifier ownership is applied and verified in Refactor 41 (R08/D08). |
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
independent set of tasks: A03 includes D02 and D08 (both verified);
A04's record/codec separation and neutral backend contract are implemented,
while composition review overlaps R09; A05 keeps the same public Tool Class and
places ToolExecutor beside the capability contract, preserving its documented
bridge to Engine; A06's execution/context separation is implemented but its
shared recovery metadata concern is now resolved by Refactor 38 under R03. No claim is made that all
Agent directory cycles disappeared.

The following table tracks the previously omitted initial items, including
completed follow-ups. The remaining items are not regressions caused by Refactor 35.

| Initial item | Current assessment and follow-up |
|---|---|
| D02 | Applied and verified in Refactor 37: callers construct OperationBinding directly and retain ordering and cancellation contracts. |
| R03 | Applied and verified in Refactor 38: ExecutionMetadata owns shared durable keys and snapshots; ToolInvocation owns stable identity. Earlier restoration behavior is preserved. |
| R06 | Applied and verified in Refactor 39: InvocationTransitions owns Tool events, ordered external transitions and state declarations for both builders and Invocation. |
| R07 | Applied and verified in Refactor 40: ContextAssembler describes preparation through private instruction, record-candidate, candidate-merge and current-input operations. |
| R08 / D08 | Applied and verified in Refactor 41, one overlapping item: GeneratorVerifier keeps its facade and Result; private WorkflowBuilder, AgentResultReceiver and the moved PipelineState separate graph construction, reception and state. |
| R09 | Refactor 42 Tool binding and declaration rules are applied and verified. Refactor 43 implements Chat construction and explicit state ownership; application verification is pending. Existing DSL behavior is retained. |
| R10 | Unimplemented: filtering_input_action/building_context_action and Team's TaskResult wording still describe different responsibilities. |
| R11 | Applied and verified in Refactor 38: Values::Serializable owns recursive conversion. Caller-specific diagnostics and distinct immutable/canonical/codec contracts remain. |

These entries identify real remaining proposals, not automatic authorization for
public behavior changes. D02, R03/R11, R06, R07 and R08/D08 are applied and verified.
Refactor 43 implements the remaining R09 candidate; verify application before closure.
R10 can be coordinated with its owning changes.
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
R03/R11 are closed. Five groups remained at that point; R06 is now applied below.
The diagram was synchronized to applied38-01 then and is now applied42-01.


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
The diagram was synchronized to applied39-01 then and is now applied42-01.


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
preparation scenarios. R07 is closed. Three groups remained at that point; R08/D08 is now applied below.
The published diagram is applied42-01; keep it until Refactor 43 application checks.


## R08/D08: GeneratorVerifier ownership (Refactor 41, applied)

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

Refactor 41 is applied and independently verified at core e87eb77f, tree
14dc8a546a4fd96e19e0713f7480ca2efa3c331a. All nine files and the full tree match.
Core 3,042 (61 pending), integration 367 (28 pending), common examples 42 and
SQLite 116 passed with zero failures, as did API/RBS, style, gem and explicit
public/Result/state comparisons. R08/D08 is closed; R09 and R10 remain.
The diagram is applied41-01.


## R09: Tool binding and declaration rules (Refactor 42, applied)

See [the boundary design and inheritance matrix](agent-configuration-and-tool-binding.md).
Base retains its preparation hook, non-Class passthrough and setting selection.
Agent::ToolBinding creates alias/filter decorators and forwards custom async
logical/physical completion. The default async path stays inherited to avoid
applying filters twice. ToolInvocation and Orchestrator retain their owners.
No Agent reference or private callback into Base is passed to ToolBinding.

Thirty-five new examples pass on both baseline and candidate. Current DSL rules
are explicit, including non-inherited model/budgets/filters, live parent lookups,
shared instructions/policy/Tool-list values and inherited aliases that nil does
not remove. This package does not unify public configuration behavior.

Refactor 42 is applied and verified at core 4a57a3c2, tree
1a43ec3fecd5457e4314afa3807eb862bbd16b52. All nine files and the tree match.
Core 3,077 (61 pending), integration 367 (28 pending), examples 42, SQLite 116
and the packaged persistence contract 41 pass with zero failures. Public
contracts, API/SPI, types, style and gem loading also pass. This closes the
first slice; the original R09 Chat/state scope is addressed below.

## R09: Chat construction and explicit state ownership (Refactor 43 candidate)

See [the Chat/state ownership design](agent-chat-and-state-ownership.md).
RuntimeChatBuilder owns provider Chat creation, settings and cached instructions.
StateWriter owns initial root/context/knowledge writes and explicit idle-Agent
mutations, using the captured root and one transaction. Both live in the existing
context_assembly directory. They hold no Agent reference or private callbacks.

Base keeps the facade, live-owner checks, root proposals and publication. Its
projection hook preserves instruction/Tool/message order and existing overrides.
The writer returns root and records only after the transaction returns; Base
publishes Journal records before replacing the live root. Initial input order,
idle checks, CAS, revisions, exception identity and rollback behavior are retained.
Unknown commits, local publication failure and application-owned outer
transactions retain their existing limitations; no new reconciliation is added.

Thirty-seven new behavioral examples pass against both Refactor 42 and the
candidate. Full core/integration/examples/SQLite and API/SPI/type/style/package
gates are recorded in the distribution. Static dependency analysis preserves
all existing cycle memberships, with one new context_assembly -> lifecycle pair.
This improves responsibility boundaries; it does not remove existing cycles.

R09 can close after Refactor 43 application verification. R10 remains open.
Retain the applied42-01 SVG until that verification. No live-LLM, live PostgreSQL,
candidate remote-CI or performance claim follows from local validation.
