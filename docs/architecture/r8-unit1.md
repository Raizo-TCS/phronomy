# r8 unit 1: Shared Context, Tool, and Execution foundations

> Current boundary: r8 unit 6 supersedes the historical Chat/SDK ownership and
> adapter extension SPI below. Agent uses LLMAdapter values; the backend owns SDK
> construction/interception; Tool owns canonical schema validation. See
> `docs/architecture/r8-unit6.md` and `docs/migrations/r8-unit6.md`.


The baseline is main `653e255a34fe4062d4beca47530e084fdd3a6ba9`, checked on 2026-09-30. The design references are the revised r8 specification and directory layout documents updated that day. This change is the first implementation unit; it does not mean that all of r8, every S1 item, or every S2/S3 acceptance condition is complete. Compatibility aliases and old APIs that only forward calls are not retained.

## Implemented responsibilities and operations

| Owner | What the shared foundation does | What remains with the caller |
|---|---|---|
| `Context::Assembly` | Calls the Policy once and validates the Plan; normalizes content, checks the final budget, and stores the Manifest | Agent obtains the snapshot, rechecks the watermark immediately before persistence, and updates the Agent execution record |
| `Tool::DefinitionSet` | Normalizes Tool definitions and validates name uniqueness and consistency with persisted definitions | Agent prepares its own Tool aliases, decorators, and runtime instances |
| `Tool::Authorization` | Evaluates facts -> requirement -> policy -> decision using immutable arguments and authorization context | Agent manages execution matching, approval state, admission results, and supervision |
| `Tool::ToolExecutor` | Handles cooperative/offloaded execution rules and results | Pool selection in Engine is delegated to the Execution mechanism binding |
| `LLMAdapter::Base` / `RubyLLM` | Handles synchronous generation and chat construction/configuration, message construction, and tool-call construction; the RubyLLM implementation translates SDK failures | Agent validates its persisted data and Tool definitions before passing them to the adapter |
| `Execution` | Owns the submit entry point, fan-out/fan-in, result composition, and cancellation/deadline/waiting rules | Engine implements pools, timers, Runtime, and FSM mechanisms |
| `Tracing::Observation` | Provides explicit observation and PII redaction without changing the actual return value | Runnable owns the invoke/stream/batch execution contract |

Context and Tool own real shared procedures, rather than merely housing thin Agent type definitions. However, current Context inputs still contain Agent-derived identifiers and provenance. This is not a redesign into a fully generic domain model. The Tool DSL base continues to use RubyLLM::Tool.

`Context::Assembly#prepare(input:, policy:, adapter_identity:)` calls the Policy outside the persistence transaction. `#store(prepared, contents:)` uses only the contents repository supplied by the caller from the same transaction; it does not start an independent transaction. Initial and follow-up Agent commits store the Manifest and the AgentExecution reference within the existing transaction. If a later write fails, the Manifest is rolled back too, and the Policy is not executed again. The existing ordering, which applies the live projection after commit, is preserved. This validates the Agent/Context part of P02; it does not complete participation in outer transactions for arbitrary domains.

Execution depends on the operations of `_ExecutionBackend`. Composition configures a deferred provider, and Engine's `ExecutionBinding` implements submit/after. Creating settled TaskResults, using map/flat_map/all_settled, and checking waiting constraints do not load Engine. Runtime is obtained only when work is actually submitted or a timer is registered. Mechanism references are consolidated here, rather than merely being renamed or nominally reassigned.

`Workflow::Completion` owns Workflow FINISH and completion values, and WorkflowRunner translates them into the FSM representation. Event/FSMProtocol/TerminalDecision, which are specific to FSMSession, live in Engine. Full separation of Agent and MultiAgent FSM-specific bindings remains outstanding.

## Public names and layout changes

| Previous location/API | New location/API | Rationale |
|---|---|---|
| `agent/context_contract/` and APIs such as `Agent::ContextPolicy` | `context/` and APIs such as `Context::ContextPolicy` | Consolidate Policy, Plan, Manifest, and validation under the owner of the shared operations |
| `agent/context_policies/default.rb` | `context/default_policy.rb`, `Context::DefaultPolicy` | Keep the concrete Policy in the same domain |
| `Agent::Context::Instruction::PromptTemplate` | `Context::PromptTemplate` | Remove the old public name under Agent |
| `Agent::Selection::{Candidate,Constraint}` | `Context::{Candidate,Constraint}` | Remove the thin Selection subdivision |
| `Agent::LLMInputPatch` / `LLMInputBuildContext` | `Context::LLMInputPatch` / `LLMInputBuildContext` | Unify ownership of hook inputs and return values |
| `ContextBudgetExceededError` | `Context::BudgetExceededError` | Represent a Context budget failure, not an LLM provider failure |
| `agent/context_assembly/` | `context/assembly.rb` plus preparation, state, and input handling directly under Agent | Separate shared Context procedures, Agent snapshot/state handling, and LLM SDK handling |
| `Agent::Context::Capability::Base` | The actual implementation, `Tool::Base` | Remove the old name and alias |
| `agent/tool_execution/tool_definition_set.rb` | `tool/definition_set.rb` | Transfer shared definition handling; keep Agent-specific construction in Agent |
| `execution_contract/` and `execution_services/` | `execution/` and the necessary `execution/concurrency/` | Consolidate operations, values, and shared rules; do not add thin subdivisions such as `execution_result` |
| `WorkerSubmission` | `Execution.submit` | Remove the forwarding-only module |
| `Runnable#trace` | `Tracing::Observation.trace` | Remove the execution foundation's dependency on observation |
| `tool/contract`, `filter/contract`, `output_parser/contract`, `agent/lifecycle_contract` | Exception files under their owning domains | Remove exception-only directories; retain existing meaningful exception constant names as actual definitions |

Custom LLM adapters implement `build_chat`, `configure_chat`, `message`, and `tool_call` in addition to complete/stream. The base class supplies a default `identity` and a nil default for `input_budget`. See `sig/phronomy/llm_adapter/base.rbs` for exact keywords and return contracts. Translate SDK-specific exceptions into LLM failures at adapter operation boundaries, preserving the original cause. Do not translate application exceptions or cancellation into unrelated provider failures.

The existing `tool_result_max_size` configuration API and logger are supplied by application composition to neutral RuntimeSettings. Remove references from Tool to the composition factory while preserving default, nil, and scoped-copy semantics. Place RBS in `sig/` and `sig/_private/`, and analyze dependencies based on implementation constants and declaration ownership.

## Progress by r8 item

| Item | This implementation unit | Outstanding work |
|---|---|---|
| DP01 Context consolidation | Main scope implemented | Broader domain inputs and public operations still require review |
| DP02 Shared Tool foundation | Shared definition, authorization evaluation, and invocation implemented | Agent FSM bindings and all parent/child authorization rules remain under DP12/P04 |
| DP03 Execution consolidation | Implemented | This does not complete the review of FSM use across all domains |
| DP04 Persistence | Not started | Facade removal and shared transaction/participation/outcome-reconciliation APIs |
| DP05 Domain persistence schemas | Not started | Consolidation of MultiAgent/Workflow storage_contract |
| DP06 LLM consolidation | Prerequisites only | Full consolidation of llm_contract and llm_adapter |
| DP07 Consolidation of thin failure directories | Implemented | This is not a redesign of every domain's failure vocabulary |
| DP08 Composition consolidation | Bindings added only | Physical consolidation of runtime/persistence/agent composition |
| DP09 Independent Embeddings domain | Not started | Placement independent of vector_store |
| DP10 Documents | Not started | Loader/splitter relocation |
| DP11 Decomposition of assembly/concerns | Main scope implemented | Agent-specific processing remains directly under Agent |
| DP12 Domain execution bindings | Partial, including the Workflow completion boundary | Full separation of Agent/ToolInvocation/Team domain decisions from FSM bindings |
| DP13 Recovery/Handoff | Not started | Ownership of domain recovery, Persistence outcome reconciliation, and parent/child operations |
| P02 Persistence participation | Validated in the existing Agent/Context transaction | Outer scopes, savepoints, and public participation APIs across multiple domains |
| P01/P03-P06 Persistence and parent/child coordination | Not started | The atomicity conditions below must be established |
| Triangle review: 155 pairs, 393 cases | Reassessment incomplete | Regenerating the diagrams does not substitute for completing the assessment |

No document claims that every NC/F/RM item has been addressed. Acceptance claims are limited to the implementation units in this table and the accompanying test evidence.

## Why Persistence is outside this implementation unit

Initial Agent admission currently reads the Team reservation inside the persistence transaction. The final design should eliminate Agent's reference to Team internals, but simply moving validation to an earlier call creates this race:

1. The parent checks that the reservation is valid.
2. Another operation cancels the reservation.
3. Agent saves its admission record in a new transaction and starts the cancelled child.

The next implementation unit needs a participation API that performs the parent-owned reservation check and records Agent admission within the same scope. The parent owns reservation rules, Agent owns admission rules, and Persistence owns participation and commit boundaries. Merely hiding the current reverse dependency, where Agent switches on parent kind to select Team, behind a new callback would not resolve it.

The unresolved details are public participation keywords/return values, races with cancellation, post-commit Runtime admission, and querying/resuming with the same child ID after interruption. Workflow halt/finish snapshots alone do not make child execution inside arbitrary actions durable. P05 must define the concrete Workflow-to-Agent/Team paths, checkpoints, and one-time result incorporation. Unknown outcomes must not be treated as success based on a single matching record; P06 must define evidence across multiple domains.

Therefore this change does not alter the existing Persistence facade, Team admission validation, or transaction boundaries for reservations and child records. These remain for the next specification and implementation unit, rather than introducing provisional code with weaker guarantees.

## Reading the analysis diagrams

Regenerate the diagrams from actual source and RBS. Preserve the existing horizontal bands, group colors, individual module boxes, and transparent text backgrounds. Arrows to M33/M41/M44 are omitted only from the display; retain them in JSON, matrices, and boundary assessments. Retire old IDs instead of reusing them.

These are measured diagrams of the revised candidate, not conceptual diagrams of a completed r8. Include remaining cycles and reverse dependencies. RBS alone cannot fully prove injected targets or dynamic dispatch that static analysis cannot observe. Combine it with execution tests for Engine mechanism bindings and domain persistence.

```bash
bundle exec rbs -I sig validate
python -m pip install -r tools/architecture/tools/requirements.txt
python -m unittest discover -s tools/architecture/tests -v
# After committing lib/sig, use this option for an unpublished candidate.
python tools/architecture/refresh_diagram.py . tmp/architecture-r8-unit1 --candidate
```

The SHA in the supplied SVG identifies the local candidate used to generate it. It differs from the SHA created when the user applies and commits the changes, so regenerate the post-application diagrams from that checkout. See the distribution package's verification report for the Ruby environment, test counts, skip reasons, unverified environments, and application procedure.
