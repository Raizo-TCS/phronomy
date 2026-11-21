# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release history for 0.14.0 and earlier is archived in
[`docs/changelog/0.14-and-earlier.md`](docs/changelog/0.14-and-earlier.md).

---

## [Unreleased]

### Changed

- Reserved Agent starts expose `Agent::ExecutionRejectedError`, with the reserved
  Agent/execution IDs and original cause, for validation failures detected before
  durable admission is attempted. Ordinary invocation errors and uncertain
  admission, recovery and observation failures keep their existing contracts.

### Fixed

- Give fresh Agent Tool children their own execution wiring instead of forwarding
  the parent's reserved ID, admission, coordination participants and observers.
  Preserve application context, cancellation and shared deadline controls.
- Keep rejected execution registration and its terminal delivery isolated from
  an existing owner with the same ID. Session startup failure after a successful
  installation uses normal owned terminal cleanup; an unregistered start never
  releases the other owner's state or drains its completion waiters.
- Retire the loaded coordinator and worker Agents of confirmed terminal Team
  runs after their observed physical work finishes, without delaying the saved
  Team result or deleting durable history. Drop terminal coordinator class
  entries while preserving active and recovery-required runs.
- Report failed Team child retirement with its identities and retain the live
  owner. Terminal `resume` can retry release without replaying business work;
  read-only `result` does not initiate cleanup.
- Isolate logger failures while reporting cancellation, physical-completion and
  timer callback errors. Later callbacks still run, queued cancellation remains
  effective, and timer accounting and Runtime delivery continue.
- Validate and snapshot Team `durable_context` before accepting a new run. An
  invalid value no longer creates an active Team execution.
- Finish an accepted Team run when its child start is definitively rejected and
  a guarded public observation confirms the reserved execution is absent. Save
  the Team failure and release its active-run slot in the same transaction;
  preserve recovery when a competing child exists or observation/commit is
  uncertain. This also handles invalid input retained by earlier versions.

### Compatibility

- The new reserved-start error and Team failure behavior change the public error
  contract. Call signatures and saved record formats are unchanged. No child
  execution is fabricated, and no new execution or coordination layer is added.
  See [Team admission rejection](docs/architecture/team-admission-rejection.md).

## [0.37.0] - 2026-11-21

### Changed

- Agent `start_reserved_async`, `resume_async` and `resume` return saved
  `OutputError` failures as ordinary execution-result hashes with `status: :failed`
  and the original diagnostic, consistently with other confirmed execution
  failures. Their TaskResult completion reports successful observation of that
  result; starting, resuming or observing the execution can still fail separately.
  Ordinary `invoke` / `invoke_async` / `stream` / `stream_async` retain their
  output-failure exception contract.

### Fixed

- Let Team consume a child's confirmed output failure through its existing result
  handling. The assignment records `failed`, then the Team applies its configured
  failure policy and releases its active-run slot after the Team result commits.
  Observing the same terminal child after restart does not run that child again.
- Preserve a legitimate `nil` Tool result in runtime events so it can be saved
  as JSON null. This also lets the existing Orchestrator `on_error: :skip`
  policy complete after a confirmed child output failure.
- Make Agent Tool collection tests wait for completed worker frames to
  return while preserving Runtime ownership registries and completed handles
  as retention checks. Production lifetime behavior is unchanged.

### Compatibility

- Exact-execution output-failure handling is an intentional public behavior
  change. Callers must inspect the returned status/error, or explicitly unwrap
  through `Agent::ExecutionObservation.from_result(result).value!` to raise the
  saved failure. Call signatures, result shapes and saved formats are unchanged;
  no new event bus, state machine or coordination layer is introduced.

## [0.36.0] - 2026-11-20

### Fixed

- Wait for accepted synchronous Agent state updates before completing Runtime
  shutdown and replacing the default Runtime. Existing execution-result waits
  and saved approval suspension keep their separate shutdown rules.
- Release failed directly dispatched Orchestrator children after physical
  completion, and release successful siblings when an aggregate failure discards
  their results. Successful returned children remain available for reuse.
  Materialize children only for started JOBs so skipped queued work does not
  leave unused owners.
- Correct the architecture overview to describe WorkflowTerminalPolicy's
  existing ownership of terminal persistence outcomes.

### Added

- Add Beta `MultiAgent::Orchestrator::ChildCleanupError` with retained child
  owners, cleanup failures, the available result and primary operation error.
  Cleanup failures remain visible even under `on_error: :skip`.

### Compatibility

- Existing call signatures, dependency requirements and saved formats remain
  unchanged. The new public error and stricter cleanup-failure reporting are an
  observable contract addition; this is not a no-public-API-change patch.
- A direct Orchestrator helper still owning an unanswered child approval keeps
  cleanup incomplete at the shutdown deadline. Ordinary standalone Agent saved
  approval shutdown/reload behavior is preserved.
- No new Runtime participant, registry, scheduler or delegation layer is added.
  Team input validation and Example 01 output acceptance are separate audit
  items and are not changed in this repair.

## [0.35.3] - 2026-11-19

### Fixed

- Allow an already accepted Agent Tool to finish its private child's release
  during graceful Runtime draining. Track that release on the existing Agent
  ownership entry without reopening new admission or adding a cleanup registry.
  A child still awaiting human approval at the finite shutdown deadline leaves
  cleanup incomplete instead of being treated as released.
- Preserve native subagent registration when `Orchestrator.with_tools` retains
  a child Tool. Tool aliases now remain consistent across durable dispatch,
  replay and hosted approval recovery. Removed Tools lose their registrations;
  ordinary subclass inheritance keeps its existing behavior.

### Compatibility and verification

- Public call signatures, dependency requirements and saved representations are
  unchanged. An unresolved private-child approval wait can still leave cleanup
  incomplete at the finite shutdown deadline; the Tool does not automatically
  approve, force-release or recover the child.
- Candidate-source examples verification passed against the existing
  llama-server with gpt-oss-20b. This does not establish resolution of the
  previously observed PEG-format failure root cause or replace post-release
  verification with the published gem.

## [0.35.2] - 2026-11-18

### Fixed

- Release completed member Agents in default SharedState coordination through
  the same lifecycle handling used by custom sharing. Normal approval waits stay
  live; invocation and release failures retain their original causes and the
  member handle when cleanup needs attention.
- Keep Runtime deadline notifications active while accepted work drains during
  shutdown, including queued Blocking operations and standalone fan-out results.
  A delayed worker result cannot win merely because its timer driver stopped
  before the worker pool drained.

### Changed

- Report incomplete Runtime cleanup if the finite shutdown budget expires with
  accepted timer callbacks still pending. No callback fires early to simulate
  cancellation, and no worker thread is forcibly interrupted. Default Runtime
  replacement still requires complete cleanup.
- Reconcile P5 progress with the published v0.35.0 and examples acceptance, and
  identify the old execution-boundary proposal as historical documentation.

### Compatibility and verification

- Public signatures, dependency requirements and current saved formats are
  unchanged. The existing `cleanup_complete?` predicate now remains false when
  the shutdown budget leaves accepted timer callbacks unfinished, so a default
  Runtime cannot be replaced after incomplete cleanup.
- This core release does not claim new published-gem examples, live LLM or SQL
  acceptance, or resolution of the previously observed LM Studio/gpt-oss
  PEG-format failure root cause. Those checks remain separate follow-up work.

## [0.35.1] - 2026-11-18

### Fixed

- Preserve Workflow states named `before`, `after`, `around` or `do` when
  compiling transitions with state_machines 0.304.0. Explicit source and target
  arguments avoid callback-key collisions while retaining transition guards.
- Avoid repeated state declaration checks when dispatching a compiled Workflow's
  automatic completion event. Guards, callbacks, external-event handling and the
  generic FSMSession contract are unchanged.
- Exclude only `regexp_parser 2.13.2` from the distributed gem because
  `json_schemer 2.5.0` fails to load after `implements` became private in 2.13.2.
  This protects application dependency resolution while allowing the upstream
  fix in 2.13.3 and later versions
  ([regexp_parser #116](https://github.com/ammar/regexp_parser/issues/116),
  [json_schemer #238](https://github.com/davishmcclurg/json_schemer/issues/238)).

## [0.35.0] - 2026-11-17

### Added

- Add public Beta `PersistenceComposition.resources` and `.agent_resources` for
  constructing external backends with the canonical full or Agent-only resource
  catalog. Both return frozen Arrays of existing Resource objects without
  creating backends, stores or Runtime. The internal StorageSchema stays private.

### Fixed

- Correct dependency-generated state-machine success assertions for both boolean
  and Transition return values. Refusal remains exactly false, and destination,
  guard order, exception and approval/resume checks remain intact. The existing
  execution boundary already normalizes successful values; product behavior and
  dependency requirements are unchanged.
- Align VectorStore AsyncClient RBS input types with the synchronous public
  operations: Numeric vectors and Integer or decimal String search limits.
- Correct current Embeddings names, LLM extension ownership, Execution client
  boundaries and the 14-site domain persistence submission inventory. Distinguish
  neutral coordinator scopes from domain transactions and retain superseded ADR
  rationale as explicitly historical.

### Removed

- Remove the unused private `Storage::AsyncClient.submit` forwarding helper.
  Domain operations already submit through their execution environments or
  Execution; public `transaction_async` and its transaction behavior are retained.

### Compatibility and verification

- External persistence backend integrations can use the public resource catalogs
  starting with v0.35.0 instead of reading private StorageSchema declarations.
  Composition owns the canonical catalog; integrations retain backend mapping
  and connection ownership. Resource identity, current saved formats, public
  transaction behavior and domain recovery policies are unchanged.
- VectorStore input type declarations now describe inputs already accepted by
  synchronous operations; this does not add coercion or change search behavior.
- This release does not resolve the root cause of previously observed
  LM Studio/gpt-oss PEG-format failures or claim to prevent recurrence.
  Published-gem examples acceptance remains separate from core verification.

## [0.34.0] - 2026-11-16

### Changed

- Route ContextPolicy item estimates directly through the protected
  `estimate_tokens` extension operation, removing the redundant private wrapper.
- Exercise Tool approval redaction through the display/snapshot path used by
  production approval requests instead of internal convenience getters.
- Replace references to an absent repository language-check script with an
  external maintainer check and recorded evidence. Correct the Storage phase
  status: P4 is implemented; the separate final P5 review remains pending.

### Fixed

- Derive default SharedState members through `Agent::Base.with_tools`, retaining
  Phronomy authoring settings and filters as custom sharing already does. A
  member's iteration limit, temperature and other configuration no longer reset
  when built-in sharing Tools are added. Preserve Tool aliases, the generated
  definition identity and default findings-store behavior.

### Removed

- Remove Handoff's old selection-unit metadata fallback and Agent Store's raw
  argument fallback. Current conversation groups and exact validated arguments
  remain the authoritative saved facts; current record writers are unchanged.
- Retire `Persistence::Migration::InitialFormatMigration` and the old
  GeneratorVerifier Result JSON conversion command, including their dedicated
  migration tests and active usage instructions. No replacement converter or
  compatibility entry point is supplied. Current codecs, Result validation and
  the separate Unit4 snapshot migration remain. See the
  [legacy-format cleanup](docs/migrations/legacy-format-removal.md).
- Remove `Runtime::ShutdownResult#success?`; use the equivalent
  `cleanup_complete?`. Keep `clean?`, which additionally requires a graceful
  shutdown.
- Remove the obsolete `SchedulerReentrancyError` subclass; use
  `EventLoopReentrancyError`, which is already raised by current execution paths.
  No compatibility aliases are retained. See the
  [cleanup migration](docs/migrations/cleanup-audit.md).
- Remove unused internal Invocation, RecoveryRules and Execution helpers, along
  with five completed development-only spec migration scripts. Keep the public
  `JournalProjection#llm_call_records` and
  `LLMInputManifest#referenced_content_refs` operations and the Scope hooks still
  used for result composition.

### Compatibility and verification

- Replace `Runtime::ShutdownResult#success?` with `cleanup_complete?` and rescue
  `EventLoopReentrancyError` instead of the removed `SchedulerReentrancyError`.
  No compatibility aliases are retained. See the
  [cleanup migration](docs/migrations/cleanup-audit.md).
- Historical pre-S3 and GeneratorVerifier Result conversion support is retired
  without a replacement command. Current record writers and saved representation
  are unchanged; this release does not rewrite existing stores. Handoff no longer
  derives groups from old selection-unit metadata, and authorization requires
  validated argument evidence. Review the
  [legacy-format migration](docs/migrations/legacy-format-removal.md) before
  upgrading applications that still consume those historical records.
- Previously observed LM Studio/gpt-oss PEG-format failures are not resolved by
  this cleanup. This release does not claim to fix their root cause or prevent
  recurrence; offline persistence/recovery checks do not establish full real-LLM
  acceptance.

## [0.33.0] - 2026-11-14

### Added

- Add public `ContextPolicyInput#input_token_limit` and
  `#with_input_token_limit(limit)` for immutable, non-expanding selection limits,
  plus protected `ContextPolicy#estimate_tokens(content)` using the same
  canonical estimator as generated Policy items. Applications can reserve input
  capacity while retaining DefaultPolicy selection without constructing private
  budget objects or calling private token-estimation helpers. These operations
  do not change model capabilities, generation settings or final validation.
- Add `Agent::Base.with_tools(definitions, id:, version:)` to derive an Agent
  class with a complete replacement Tool map and explicit definition identity.
  The factory preserves Phronomy authoring settings and independently copies
  filter lists; configured callable instances remain shared. Custom SharedState
  uses this public operation after merging member and application Tools. General
  Agent subclass inheritance remains unchanged.
- Add `MultiAgent::SharedState.sharing(provider, id:, version:)` and the public
  `SharedState::Binding` value. A synchronous provider opens one application-owned
  store for an invocation and supplies Tool definitions for each member/cycle.
  Applications define their own records, search arguments and cleanup without
  overriding SharedState private methods. Custom sharing requires an explicit
  aggregation block and does not inject the default findings Tools or append
  stored records to member prompts.
- Include the sharing provider's stable ID and semantic version in custom
  generated Agent definition identity. Default SharedState retains its existing
  built-in Tools, prompts and instrumentation revision 1. The extension adds no
  database adapter, ContextPolicy implementation or durable sharing lifecycle.
- Release terminal custom-sharing members through the public Agent lifecycle
  operation. Normal Agent approval waits keep the invocation and provider open.
  `SharedState::MemberLifecycleError` reports failed release or a custom
  `invoke` override returning a suspended result prematurely, with the Agent and
  available result/error details. It does not automatically answer approvals or
  release a pending execution; application providers retain responsibility for
  resource cleanup and recovery policy.

### Changed

- Reuse the immutable argument schema prepared by an explicit `parameters`
  declaration. Each Tool instance compiles its own validator on first use.

### Fixed

- Build each human-facing Tool approval item from the Tool's public
  `approval_display(arguments:, facts:)` result. A Tool without this operation
  contributes empty argument and fact maps to new approval requests. Tool
  execution and policy evaluation still receive their original inputs.
- Apply the default approval display's sensitive-value check to values inside
  a Tool's redacted hash or array arguments, including copies used as fact keys.

### Security

- Use patched ActiveRecord 8.0 development dependencies, including ActiveSupport
  8.0.5.2 or later in the 8.0 series. Remove unused ActiveJob and SQLite3
  development dependencies; the examples retain the dependencies they use.
  The published gem's runtime dependencies are unchanged.
- Provide Bundler Audit in the development bundle and check the complete
  dependency set in pull-request CI and immediately before release publication.

### Compatibility and verification

- The new SharedState sharing, Agent Tool composition and Context budgeting APIs
  require 0.33.0 or later and remain Experimental. Default sharing and ordinary
  Agent subclass inheritance retain their existing behavior. Custom sharing is
  synchronous and invocation-scoped; it does not add durable sharing recovery.
- Approval display is selected by each Tool. Custom Tool implementations without
  `approval_display` expose empty display maps; execution and policy evaluation
  still use the original arguments. Review custom display overrides for safe
  human-facing fields when upgrading.
- Observed LM Studio/gpt-oss PEG-format failures remain unresolved.
  The existing adapter identifies known errors and bounds retries; this release
  does not claim to fix their root cause or establish full real-LLM acceptance.
  The latest full examples verification recorded 102 passed, 1 failed and no
  skips (Example 22: HTTP 400). A separate Qwen Example 22 run completed all three
  cycles, but took 2,220 seconds and does not replace the full verifier result
  or satisfy its 240-second per-example limit.

## [0.32.0] - 2026-11-03

### Added

- Add `Agent#start_hosted`, `Agent::HostedInvocation` and immutable
  `Agent::ApprovalWait` for safely detaching an exclusively owned standalone Agent
  at its first committed Tool approval wait. A new incarnation can use the
  existing `load` and `approve` operations to continue the same execution.
- Add `Agent::Store#standalone_approval_wait` to query the committed approval fact without
  transferring a live worker claim. Delivery deduplication, exclusive claims and
  verified worker termination remain application responsibilities. Standalone
  detachment does not transfer parent Workflows or shared children; supported
  direct-child handoff and saved Workflow events are separate APIs below.

- Add `Workflow#send_saved_event` to restore a declared wait by Workflow instance
  ID and expected revision before applying an event. The host can reject a
  delayed delivery even when the same Workflow later returns to an identical wait.
- Allow an Orchestrator's hosted handle to detach its local parent and direct
  child together at a saved child Tool approval. The host supplies the child's
  execution and approval request IDs and retains the parent's execution ID for
  resumption on another worker. Both workers can remain alive.
- Add `MultiAgent::Orchestrator#approve_hosted_child` to answer a restored
  direct child's approval with a hosted handle. If the same execution asks for
  another approval, the worker can release the pair at the new wait. A third
  worker can restore that wait without replaying the earlier Tool call.
- Add `MultiAgent::Orchestrator#unload_with_completed_child!` for a worker
  that has finished a direct child dispatch. It can release the local owners
  while keeping the conversation, execution results and native slot history.

### Fixed

- Bind native subagent dispatch context to each prepared Tool instance so that
  cached Tool methods do not keep completed Orchestrators alive after unload
  (Issue #440). Saved SQLite execution and conversation history is preserved.
- Keep distinct native Tool call/result pairs when a provider reuses its call ID
  in later responses on the same Agent. A subsequent request can use the saved
  conversation without executing either Tool again to rebuild context.
- Restore mutable Workflow context fields from durable checkpoints when
  delivering a saved event or starting another invocation of the same instance.
  Actions can update nested strings, arrays and hashes without changing the
  original checkpoint.
- Continue using an Agent after a human rejects a Tool call. Model input for the
  next turn omits the rejected, incomplete Tool exchange. The original journal
  and public conversation history remain available for inspection.

### Compatibility and verification

- Worker APIs require 0.32.0 or later; applications using `start_hosted` cannot
  run against 0.31.0. The existing [0.31 storage and Agent Tool migration
  requirements](docs/migrations/0.31.md) still apply. This release does not add a
  persistence mapping migration or change those stored execution formats.
- Native handoff and completed-owner release cover one direct child in an
  isolated dispatch batch. Delivery deduplication, exclusive claims, ACKs and
  verified worker termination belong to the application. General graph transfer,
  multi-host fencing, supervisor restart and recovery of unknown external Tool
  effects are not established by these examples.
- Worker acceptance uses fixed HTTP responses, actual Ruby processes and SQLite,
  including Ubuntu 24.04 and 26.04. It does not establish live-model acceptance.
- LM Studio/gpt-oss PEG parsing remains a known unresolved limitation. The latest
  pre-release standard verifier reported 101 passed, 2 failed and 0 skipped;
  Examples 01 and 22 received provider PEG errors, also reproduced before Worker
  support. Known-error identification and bounded retry do not fix the provider's
  root cause. These two failures are tracked separately from Worker acceptance.

## [0.31.0] - 2026-10-25

### Added

- Add explicit Agent `schema_delivery: :native | :none` across execution entry
  points and GeneratorVerifier. Local structured-output validation is identical
  in both modes; existing calls retain native delivery.
- Add `Agent#transcript_messages` and its async counterpart to read immutable
  Message values without application knowledge of Journal storage.
- Add `Tools::Agent::CleanupError` (`tool.agent_cleanup_failed`) with the child
  Agent, successful result and primary/cleanup failures needed to diagnose failed
  release and retry `child_agent.unload_async` without repeating the invocation.

### Persistence

- Save new output contracts as version 2 with the delivery choice and retain their
  schemas even when no schema is sent. These executions use envelope 0.3, rejected
  by older readers. Existing version-1 contracts remain native and readable.

### Fixed

- Preserve streamed refusal facts even when native schema delivery is omitted.
- Release the one-shot Agent owned by `Agent.run_once` through `Agent.open_scope`.
  Preserve the invocation value or original exception when release succeeds;
  report unsafe or failed release through `Agent::ScopeCleanupError` with the
  result, primary error and scope needed for a release-only retry.
- Give each Agent-backed Tool call explicit ownership of its fresh child and
  ephemeral Store. Complete release after logical and physical invocation
  completion, without occupying a worker merely to wait. Preserve approval,
  cancellation, independent leases, retention and recovery restrictions.
- Acknowledge terminal execution waiters before publishing their result while
  retaining each operation's physical lease until its work actually finishes.
- Stop completed Agent Tool handles from retaining released children through
  generated callback owners, temporary state-machine tracker context or completed
  `ExecutionChange` wiring. Clear execution-only references after commit and any
  ambiguous-outcome readback, including failure paths. Keep single-use guards,
  saved results, session ownership and recovery behavior intact.

### Changed

- Both synchronous and asynchronous Agent Tool calls now use the child's
  `invoke_async`. An override of only `invoke` no longer changes synchronous
  Agent Tool execution; update custom child subclasses accordingly.
- Agent Tool cleanup failures are surfaced and diagnosed, including after an
  outer observer cancels. A general Tool error-suppression policy cannot hide
  failed child release.

### Verification and migration

- Read the [0.31 migration notes](docs/migrations/0.31.md) before upgrading stored
  executions or custom Agent Tool subclasses. Deploy readers that support
  AgentExecution 0.3 before writing new structured executions; older readers
  cannot read these records, including completed executions. Existing 0.2 records
  and version-1 native output contracts remain readable without a read-time rewrite.
- LM Studio/gpt-oss PEG output parsing remains an unresolved external limitation.
  Existing known-error identification and bounded retry are not a root-cause fix.
  The DX1/DX2 live normal path, streaming, Tool use and history restoration remain
  unverified in that environment. This release relies on source review, offline
  regressions and CI; it does not claim completion of live LLM acceptance.
  Historical initial success and bounded retry/stop evidence retain their limited
  scope; retry recovery and recurrence resolution remain unverified.


## [0.30.1] - 2026-10-24

### Documentation

- Translate historical r8 unit 1/2 architecture notes and durable semantic
  coordination records into English, preserving API names, executable commands,
  requirement IDs, dates and the original validation limits.
- Repair ADR-029's link to the recovery-contract document and its English heading.

Runtime behavior, public APIs and dependency requirements match 0.30.0.

## [0.30.0] - 2026-10-24

### Added

- Agent `output_schema:` and `OutputParser::JsonSchemaParser` provide strict,
  immutable JSON results. Refused, incomplete and invalid output raises
  `Agent::OutputError`; native schema delivery is preserved through Tool rounds,
  approval and recovery without output repair or replaying confirmed Tool work.
- Explicit `LLMAdapter::LMStudio` selection identifies the known generated-format
  rejection as `llm.provider_output_parse_failed`, retaining the actual HTTP
  status and original SDK cause. Opt-in retry resends the same eligible,
  non-streaming gpt-oss-20b request at most once, without replaying Agent,
  Workflow or Tool work. Ordinary SDK retries are disabled in this backend's
  private snapshot; the default backend and global SDK settings are unchanged.

### Changed

- Generate architecture SVG metadata in English, including repeated formatting.

- GeneratorVerifier owns immutable evaluation Results, explicit approval routing
  and Agent lifetime. Use `accepted?`, `termination_reason` and
  `raise_if_unaccepted`; `output_failed` distinguishes invalid output from a
  completed evaluation that reaches `iteration_limit`. Acceptance reports the
  configured conditions, not the truth of generated content.
- Agent scopes and GeneratorVerifier scopes await a directly returned TaskResult
  before releasing their owned Agents. Cleanup preserves the primary failure,
  successful value and handles needed to retry release.
- Tracing usage is a plain token-count Hash. Custom tracer/exporter callers must
  project LLM-domain TokenUsage values before crossing the tracing boundary.
- Require Faraday 2.14.4 and faraday-net_http 3.4.4 as the tested HTTP support
  floors. Concrete LLM/Embeddings adapters translate recognized network failures
  into their public TransportError types while preserving causes and callback
  exceptions; cancellation and unknown internal failures are not broadly mapped.
  Strict JSON decoding requires JSON >= 2.21.2 and < 3.

### Removed

- GeneratorVerifier parser fallback/repair hooks, `trusted`/`trusted?`,
  `raise_if_untrusted` and `LowConfidenceError`. Migrate saved Result data with
  `scripts/migrate_generator_verifier_result.rb`; no compatibility aliases are
  provided. See the [Result and lifetime contract](docs/architecture/generator-verifier-lifecycle-result.md).

### Fixed

- Preserve each SharedState member's explicitly configured model when creating
  its internal instrumented Agent. Keep ordinary Agent inheritance and the
  global fallback for members without an explicit model unchanged.
- Preserve canonical assistant-message metadata through Agent Tool rounds,
  imports, persistence and recovery. The RubyLLM backend retains supported
  thinking text/signatures and raw reasoning, including final streaming
  responses, and delegates wire rendering to the existing SDK. Incompatible
  continuation scope/version is rejected before inference; legacy messages
  without this metadata remain usable. No database migration is required. See
  [continuation compatibility](docs/architecture/llm-continuation-metadata.md).
- Enforce `Agent.max_iterations = N` as at most N logical LLM calls per
  execution, including the first and final response. Remove the premature FSM
  cutoff that stopped the ninth single-Tool round before call ten. Tool count,
  approval/resume, streaming chunks and SDK HTTP retries do not consume extra
  logical calls; this limit does not bound physical HTTP attempts or Tool count.
  Preserve the admitted limit and consumed-call records across approval,
  recovery and a fresh Runtime/database pool. Legacy executions without the
  saved limit use the current class setting. A final response on call N succeeds;
  Tools requested on call N retain their results, and call N+1 raises the existing
  `RecursionLimitError`. Zero permits no call; invalid limits fail before inference.
  Generic Engine transition protection remains in place. This correction can
  allow work previously stopped too early and stop runs previously able to reset
  their budget on approval. Deploy at a quiescent Runtime boundary; see
  [iteration budget migration](docs/architecture/agent-iteration-budget.md).

### Verification and migration

- Real LM Studio acceptance identified HTTP 400 PEG failures, performed one
  identical-request retry, and returned the final error at the adapter's own
  limit after the second failure. A separate application invocation succeeded
  initially with HTTP 200: two application invocations, three generation POSTs.
  This is not recovery by retry within one invocation. Recovery by retry,
  recovery rate, the PEG root cause and recurrence resolution remain unverified.
- Review the [structured-output migration](docs/architecture/structured-output-and-scope.md),
  [continuation compatibility](docs/architecture/llm-continuation-metadata.md),
  [iteration budget migration](docs/architecture/agent-iteration-budget.md) and
  [LM Studio retry policy](docs/architecture/lm-studio-output-failures.md) before
  upgrading persistent or in-flight applications.

---

## [0.29.0] - 2026-10-13

See the [0.29.0 release record](https://github.com/Raizo-TCS/phronomy/releases/tag/v0.29.0).

---

## [0.28.0] - 2026-10-09

The architecture notes below were already included in this release and carried
unchanged in the 0.29.0 changelog. They are retained from the former Unreleased
section and are not new 0.30.0 changes.

### r8 first implementation unit (breaking)

- Move Context policy/plan/manifest/budget/prompt operations into `Phronomy::Context`.
  Agent retains snapshot, journal and lifecycle ownership. Manifest and execution
  references remain written within the same transaction.
- Make `Tool::Base` the actual implementation; move common definition and
  authorization operations into Tool. Remove the old Agent Context namespace.
- Move chat construction and SDK failure translation into the LLM adapter.
  Custom synchronous adapters must implement the expanded construction SPI.
- Unite execution contracts and services in `execution/`; move FSM values and
  scheduling bindings to Engine, observation to Tracing. Keep result/control
  rules independent of Engine startup. Update Ruby/RBS analysis and diagrams.
- Remove empty contract-only subdivisions and old API aliases. This unit does
  not complete r8 Persistence, parent admission or all domain FSM separation.
  See [the scope and migration report](docs/architecture/r8-unit1.md).

### Changed

- Add public Beta `Storage::AsyncClient#transaction_async` and route 16 existing
  durable Agent/Workflow/coordination execution units through its private submit
  boundary. Preserve transaction/savepoint, result reconciliation and admission
  policy; do not add cancellation or timeout to existing terminal writes.
- Move StoredContents into `content_store/backends/` without changing its
  constant or behavior. Complete P4; see the
  [Storage client guide](docs/migrations/storage-async-client.md).
- Preserve transparent text panels and module outlines in generated diagrams.
  Hide arrows into M33/M41/M44 as a display choice; keep their measured source
  dependencies, evidence and complete matrix.

- **Beta API receiver migration:** move VectorStore `add_async`, `search_async`,
  `remove_async`, `clear_async` and Embeddings `embed_async` onto the public
  feature-specific `AsyncClient` objects. Synchronous backend methods and
  concrete class names remain unchanged. Remove the inherited async methods
  and `VectorStore::AsyncBackend`; see the
  [migration guide](docs/migrations/vector-async-clients.md).
- Split VectorStore/Embeddings implementations into collapsed `backends/`
  directories. Synchronous RBS uses structural cancellation; separate client
  signatures retain TaskResult and the full execution token. Complete P3 and
  remove the remaining backend-to-Engine edges from the measured graph.

- Separate the synchronous LLMAdapter SPI, RubyLLM implementation and internal
  AsyncClient. Adapter authors implement only `complete` and `stream`; default
  configuration, provider behavior, admission/cancellation and Agent event
  delivery remain unchanged. See
  [ADR-059](docs/decisions/059-backend-contracts-and-async-clients.md).
- Separate responsibility groups from the diagram's B1-B6 display layers. Add
  the source-derived SVG/matrix generator and Architecture CI boundary gate;
  retain individual module boxes, stable module IDs and the earlier horizontal
  layer layout with topical columns. Separated Contracts belong in B5 beside
  the independent Engine group; clients, implementations and pending mixed
  backends are displayed in B4. Storage/ContentStore migration remains pending.

---

## [0.27.0] - 2026-09-24

### Changed

- Separate application Runtime reset and configuration replacement into
  `runtime_composition/global_runtime.rb`. Configuration access no longer owns
  Runtime lifecycle control; the reset API, shutdown ordering, timeout behavior,
  and configuration defaults are unchanged. See
  [ADR-039](docs/decisions/039-runtime-configuration-lifecycle-ownership.md).
- Group root implementations and entry-point exceptions by responsibility:
  common definitions, Engine/FSM execution contracts, Recovery, Workflow,
  Agent lifecycle contracts, LLM contracts, configuration, and feature APIs.
  Preserve public constant names, API signatures, stored formats, and lifecycle
  loading. Reserve the direct source root for version and namespace/loading
  files; share the three equivalent immutable-copy helpers. See
  [ADR-038](docs/decisions/038-responsibility-based-source-layout.md).
- Move the shared `Phronomy::Error` base exception to `common/error.rb` and
  define ownership rules for general common definitions. The public constant,
  subclass hierarchies, and rescue behavior are preserved. See
  [ADR-037](docs/decisions/037-common-definition-ownership.md).
- Group Context Policy and hook contracts, values, Manifest representation,
  and Plan validation under `agent/context_contract/`. Zeitwerk collapses the
  directory so the existing `Phronomy::Agent` constant names, Policy/hook
  protocols, and Manifest format remain unchanged. Agent execution and Context
  assembly retain their existing responsibilities. See
  [ADR-036](docs/decisions/036-context-contract-ownership.md).
- Move the internal `Phronomy::Agent::ToolExecutor` to
  `Phronomy::Agent::Context::Capability::ToolExecutor`, alongside the default
  Tool invocation contract, without an alias for the old internal constant.
  Public Tool names, `call_async` arguments, execution modes, Runtime routing,
  and Agent-owned authorization/result handling are preserved. See
  [ADR-035](docs/decisions/035-tool-executor-capability-ownership.md).
- Move `Phronomy::Agent::HandoffRunner` to
  `Phronomy::MultiAgent::HandoffRunner` without a compatibility alias on the
  architecture refactoring branch. Handoff edges and Policy remain in Agent;
  execution, persistence formats, cancellation and recovery behavior are unchanged.
  See [the migration guide](docs/migrations/handoff-runner-multi-agent.md).

---

## [0.26.0] - 2026-09-14

### Changed

- Rename the public completion type to `Phronomy::TaskResult`; remove `Task`
  without a compatibility alias in this development release.
- Remove `Orchestrator#fan_out` and `#fan_out_async`. Use `dispatch_parallel`
  for Agent-specific construction/knowledge/concurrency policy, or Execution
  for application-defined JOB composition.
- Preserve cancelled states and original cancellation errors across result
  transformations, independently of failures that carry CancellationError.

### Added

- `TaskResult#flat_map`, `.all_settled`, and immutable input-order Outcome records.
- `Execution.run_async` / `.run` for shared runtime fan-out/fan-in, explicit
  invocation context, whole-execution timeout/cancellation and partial snapshots.
- `Execution#observe` for scoped continuations of externally owned results.
- Optional `invocation_context:` on `Blocking.call_async`, with one-way combined
  context and individual controls shared with Agent admission.

### Fixed

- Dispose finished execution subscriptions and timers while retaining required
  physical completion tracking. Orchestrator reuses the common Execution engine.

See [Result composition and Execution](docs/async-composition.md) for migration,
completion boundaries, cancellation and application responsibilities.

---

## [0.25.0] - 2026-09-12

### Added

- Public `Task.completed` / `Task.failed` factories for application-owned settled results.
- `Blocking.call_async` for non-waiting submission of synchronous application work.

### Fixed

- Reject waiting OffloadPool admission from EventLoop before creating an operation.
- Add runtime dependency constraint `json < 3` to prevent Faraday/RubyLLM JSON
  parser incompatibilities from resolving in consumer environments.

- Run recovered output filtering inside the ordinary Agent FSM so filter
  exceptions commit a failed execution and release admission, including after
  another restart. Preserve explicit filter blocking as the `blocked` status.
- Propagate a coordinator's blocked outcome, and a worker's blocked outcome
  under `on_error: :raise`, to Team failure. Preserve skipped worker errors and
  committed failure precedence over later cancellation across restart.
- Keep Recovery content materialization, approval restoration reads, and F1
  resolution readback off EventLoop. Apply prepared invocation state only on
  EventLoop, reject stale results, and retain confirmed resolution facts when
  later content reads fail.
- Avoid reading Orchestrator Knowledge again while constructing invocation-owned
  Tools; those children inherit the Knowledge already saved with their slots.

---

## [0.23.0] - 2026-08-29

### Four-category Context Policy SPI and transaction boundary (ACS-04)

#### Added

- Public immutable `ContextPolicyInput` typed values for `instruction`,
  `knowledge`, `tools`, and indivisibly grouped `conversation`.
- Agent-class `context_policy <instance>` binding for reusable Application
  Context strategies, with built-in Default fallback.
- Small ContextPolicy helpers for current-call generated instruction, Knowledge,
  and conversation items.
- Framework trace boundary around ContextPolicy invocation without standard-trace
  inclusion of full Policy input/Plan content.

#### Changed

- `ContextPlan` now directly carries ordered output material in the same four
  semantic categories.
- Default Policy uses deterministic recent-conversation / stable-fit Knowledge
  selection with an approximately 60/40 variable budget split and preserves the
  effective Tool set.
- Custom Policy may select/reorder a subset of effective Tools; arbitrary
  schema-only runtime Tool creation remains outside ACS-04 because durable
  runtime Tool identity/wiring is not defined.
- ContextPolicy executes outside Phronomy Persistence transactions. The durable
  base/revision is revalidated before the short Manifest/execution commit.
- Context assembly policy version is `8`.

#### Removed

- `ContextRequest`, `ContextPolicyDescriptor`, `ContextPolicyRegistry`, and
  `DerivedContentSpec`.
- Intermediate selection-unit/policy-parts machinery superseded by the typed
  four-category SPI: `Selection::Unit`, `Selection::Validator`,
  `DependencyAwareUnitBuilder`, `RequiredContextResolver`,
  `RecentFirstSelector`, and `TokenBudgetPacker`.
- Descriptor persistence/reconstruction and old `ContextPlan` fields
  `selected_unit_ids`, `derived_contents`, `ordering_hints`, and
  `policy_descriptor`.

### Workflow Runtime admission and durable terminal barrier (ACS-13)

#### Added

- ADR-026 defining opaque process-local Workflow admission ownership,
  admission-before-hydration ordering, and FSMSession-integrated terminal
  persistence.
- Explicit Workflow terminal persistence outcomes: known success, known failure,
  and fail-closed outcome uncertainty.

#### Changed

- Workflow admission ownership no longer reuses the future `fsm_session_id`.
  EventLoop acquires a separate opaque owner token before durable load and binds
  the concrete FSMSession routing ID only after hydration.
- Durable Workflow halt/completion now remains nonterminal while the final
  snapshot is saved. The save result returns to the same FSMSession, and only a
  known-successful result permits `HALTED` / `COMPLETED`, admission release, and
  caller Task settlement.
- Portable known Persistence failures follow the Workflow error path. An
  arbitrary storage/transport error whose commit outcome is not established is
  treated as outcome-unknown: the success barrier stays closed and the
  `workflow_instance_id` admission remains fail-closed/recovery-required.
- Workflow persistence result handling is backend-topology neutral; the FSM does
  not depend on local/network/database transport details.

### Process-local Agent ownership and Runtime admission (ACS-12)

#### Added

- ADR-025 defining one mutable live Agent owner per `agent_id` per Runtime and
  EventLoop-owned same-process top-level execution admission.
- `Agent::Base.get(agent_id)` for process-local live-owner lookup without
  Persistence I/O.
- `AgentAlreadyExistsError` for create/new identity conflicts and
  `AgentPurgedError` for stale references after successful purge.

#### Changed

- Repeated `Agent.load(agent_id, persistence:)` returns the exact existing live
  Agent object; a durable-only Agent is hydrated once, and a missing durable
  Agent remains a strict `Persistence::NotFoundError`.
- `new` / `create` mean creation only and reject an identity that is already
  live or already durable instead of materializing a second mutable owner.
- EventLoop acquires the same-Agent top-level execution slot before initial
  Offload/Persistence work. Suspension retains that slot; known durable terminal
  completion releases it; uncertain durable outcomes remain fail-closed.
- Persistence `executions.create_active` / atomic admission remains the durable
  second line of integrity defense rather than the primary same-process lock.
- Runtime-lifetime Agent ownership is released on clean Runtime shutdown.
  Successful `purge!` is the explicit earlier destruction boundary and makes
  the stale Agent object permanently unusable before the identity can be reused.

### EventLoop single-writer Agent Runtime (ACS-11)

#### Added

- ADR-024 defining EventLoop as the single writer of Phronomy-managed live
  Agent execution state and operation-specific Offload command/result apply.
- Runtime read-only Agent execution-owner lookup for approval/live-owner
  routing without exposing mutable execution internals.
- Provider result authority using current FSMSession/FSM state plus semantic
  `llm_call_id`; stale Provider results are consumed without advancing the FSM.

#### Changed

- Agent initial preparation, follow-up Manifest preparation, approval resume,
  and terminal durable commits now return values from OffloadPool and apply
  committed live-state advances only on EventLoop.
- AgentInvocation owns FSM-local uncommitted Provider/Tool/runtime facts.
- Tool authorization captures Agent identity and Tool description data before
  worker execution; the authorization worker receives no live Agent, Tool, or
  ToolInvocation reference. Application-owned approval/facts/requirement
  callables remain explicit behavior handles.
- `ApprovalEvaluationRequest` is value-only: Agent identity is exposed as
  `agent_id`, `agent_definition_id`, and `agent_definition_version`; Tool
  identity/description is exposed through `tool_name` / `tool_schema`.
- Tool authorization/execution outcomes carry semantic `tool_invocation_id`
  and are applied by the Tool FSMSession.

#### Removed

- `AgentExecutionActivation`, `Agent::ActivationRegistry`,
  `Runtime#__agent_activations`, and the `phronomy_activation` config bridge.
- Live-object accessors `ApprovalEvaluationRequest#agent` and
  `ApprovalEvaluationRequest#tool`; approval policies use value identity and
  Tool-description fields instead.


### Semantic Multi-Agent Handoff and shared Selection

#### Added

- `Phronomy::MultiAgent::HandoffPolicy` with required, forbidden, and selectable
  transfer rules for current request, history, Knowledge, and Tool exchanges.
- `Phronomy::MultiAgent::Runner.new(main_agent:, handoffs:)` as the public
  semantic Handoff coordinator.
- Typed private Handoff request/context/provenance values, explicit
  `AgentExecution` `:handed_off` terminal semantics, and Runtime/EventLoop-owned
  active-Agent coordination.
- Shared `Phronomy::Agent::Selection::Candidate`, `Unit`, `Constraint`, and
  validation machinery for Context and Handoff selection.
- ADR-016 and the 0.22 migration guide for the semantic Handoff clean break.

#### Changed

- Handoff is now an explicit Source-to-Target responsibility transfer rather
  than sentinel Tool-result routing. Generated Handoff Tool names are private
  transport details only.
- Handoff Context is projected from the effective Source Manifest, materialized
  immutably with provenance, and may cross Agents backed by different Persistence
  adapters without adopting Source material into Target Journal/Knowledge.
- Target Context Policy remains the final per-LLM-call selection authority;
  transferred material enters Target assembly as selectable Context candidates.
- The active Target persists across user turns and Runner-facade recreation while
  the same main Agent instance and Runtime remain alive. Runtime/process reset
  intentionally does not restore active-Agent continuation.
- Context assembly policy version is now `7` for the shared Selection and
  Handoff-Context contract.

#### Removed

- `Phronomy::Agent::Runner`, the `agents:` / `routes:` Runner API, sentinel-map
  routing, and Agent-owned `_add_handoff_tool` / `_handoff_tools` mutation.
- `Phronomy::Agent::ContextCandidate` and
  `Phronomy::Agent::ContextSelectionUnit`; internal callers use the shared
  `Agent::Selection` model without compatibility aliases.

### Unified Persistence and durable-state ownership

#### Added

- `Persistence#workflow_states` with optimistic revision checks for durable Workflow snapshots.
- Runtime-local Agent execution ownership outside Persistence; ACS-11 now places the mutable live-state authority on EventLoop.
- `Agent::Base.live_for_execution(execution_id)` for resolving the current process's live owner Agent without reloading Agent or Execution state from Persistence.
- Owner-aware Workflow admission keyed by durable `workflow_instance_id`; ACS-13 now uses a Runtime-only opaque owner token that is separate from concrete `fsm_session_id` routing.
- ADR-014 and the 0.19 migration guide for the unified durable-state architecture.

#### Changed

- Live Agent instances remain authoritative for AgentRoot/Journal state after hydration, while EventLoop owns active execution-state mutation. Context Policy and follow-up Manifest preparation use those local views instead of reloading mutable Agent state for freshness.
- `Phronomy.configuration.persistence` is the global durable backend for Workflows and for Agent `new`/`create` calls that do not explicitly inject another Persistence instance.
- Agent durable writes use optimistic revision/Journal-position guardrails; conflicting external writes fail instead of being silently reloaded or merged.
- Approval suspension/resume preserves the same process-local Agent/AgentInvocation owner. Approval remains an Agent-instance operation; callers with only an `execution_id` resolve the EventLoop-backed live owner with `Agent::Base.live_for_execution` (or the expected concrete Agent class) before calling `agent.approve` / `agent.approve_async`.
- Workflow durable I/O runs outside EventLoop through OffloadPool. Terminal/halted snapshot persistence now completes inside the owning FSMSession lifecycle; only a known-successful save permits normal terminalization and admission release. Workflow admission remains process-local; optimistic revisions detect stale commits across processes but do not prevent duplicate execution or undo already-performed external side effects.
- Workflow `workflow_instance_id` is distinct from one concrete Runtime FSMSession identity; generic application `session_id` is not a Phronomy core domain identity.

#### Removed

- `Phronomy::StateStore`, `StateStore::InMemory`, `Workflow.define(..., state_store:)`, `Configuration#state_store`, and per-invocation `config[:state_store]`.
- `Persistence#activations`; live Agent execution state is Runtime-only. The transitional ActivationRegistry is subsequently removed by ACS-11.
- Class-level `Agent::Base.approve` / `Agent::Base.approve_async` routing APIs and their caller-supplied `persistence:` argument; approval execution now goes through the resolved live Agent instance.

### Public API façade and typed contracts

#### Added

- `Phronomy::Tool::Base` as the application-facing Tool authoring façade. It is
  an exact alias of `Phronomy::Agent::Context::Capability::Base`, so existing
  Tool definitions remain compatible and share the same class identity/DSL state.
- Initial hand-written RBS signatures for the primary application API and
  explicit extension SPIs, with a dedicated RBS validation CI job.
- ADR-015 defining Tool façade ownership, the LLMAdapter SPI, RBS scope, and
  extension dependency direction.

#### Changed

- `Phronomy::LLMAdapter::Base#complete` and `#stream` are explicit Beta extension
  SPI methods. Phronomy continues to own `complete_async` / `stream_async` and
  OffloadPool integration.
- VectorStore and Embeddings backends expose synchronous implementation contracts;
  their framework-provided async convenience methods offload through Phronomy and
  return `Task`.
- `InvocationContext` construction is classified consistently with its documented
  Beta application API.
- Generic Agent invocation identity is removed: `InvocationContext` no longer
  exposes `thread_id` / `session_id`, Agent invocation APIs no longer accept
  `thread_id:`, and no replacement generic correlation identity is introduced.
- The canonical `JournalRecord` representation no longer contains
  `correlation_id`; legacy durable Hashes containing the removed key remain
  readable without an eager data rewrite.
- Tool approval notification/policy parent identity now uses canonical Agent
  `execution_id` instead of `agent_invocation_id`; new suspended-execution
  approval data uses the same parent identity.
- Legacy embedded suspended approval hashes remain readable by deriving the
  logical parent from their enclosing Agent execution; historical
  content-addressed audit bodies are not rewritten.
- Agent, Tool, and Multi-Agent concrete `FSMSession` instances no longer reuse
  domain/context IDs as EventLoop routing targets. Async callbacks use
  session-local event sinks, and Provider completion is routed to the owning
  FSMSession before EventLoop validates/applies `llm_call_id`-bound result
  state. Workflow retains its pre-load admission ordering through a private
  single-use FSMSession identity reservation; opaque Workflow admission
  ownership remains ACS-13 work.
- OutputParser `parse` is classified as the public subclass extension point that
  concrete parsers implement.

### OffloadPool execution model

#### Changed

- Renamed `BlockingAdapterPool` to `OffloadPool` and `Runtime#blocking_io` to
  `Runtime#offload`; configuration keys now use `offload_pool_size` and
  `offload_queue_size`, and metrics now use `offload_pool_*` names.
- Simplified Tool execution modes to `:cooperative` and `:offloaded`.
  Workload classification (I/O-bound versus CPU-bound) is application-owned.
- CPU-bound synchronous Tools may execute through the bounded OffloadPool;
  Phronomy does not guarantee CPU isolation, CPU/I/O fairness, or parallel
  speedup for pure Ruby CPU work.
- Framework-owned EventLoop-origin offload submissions use non-blocking queue
  admission so a full worker queue raises backpressure instead of blocking
  the EventLoop control thread.
- `OffloadPool#submit` now returns the common caller-facing `Phronomy::Task`.
  OffloadPool queue/worker/timeout/abandonment state is held by a private
  Operation record rather than by a second completion-handle class.
- Submit cancellation now settles the caller-facing `Task` immediately.
  Cancellation before worker start prevents execution; cancellation after worker
  start marks the private Operation abandoned while allowing the synchronous
  worker to finish without asynchronous `Thread#raise`.
- Monotonic deadlines carried by an OffloadPool submit cancellation token are
  promoted by the Runtime timer queue, so cancellation completion does not
  require a polling Thread.
- Independent notification callbacks now isolate subscriber failures. An
  `StandardError` from one `CancellationToken#on_cancel` or `Task#on_complete`
  callback is logged and does not suppress later subscribers.
- `Task#wait_result(timeout:)` is the waiter-local synchronous timeout bridge.
  It does not settle or cancel the Task; operation-wide cancellation is
  represented by the CancellationToken supplied to the creating API.
- `offload_pool_abandoned_total` is the cumulative number of operations whose
  caller-facing submit timeout or cancellation settled after worker execution
  started. `offload_pool_abandoned_active` is the current number of those
  abandoned operations whose synchronous workers still occupy pool capacity.
- Named Runtime pools remain available for application-managed resource
  isolation and capacity planning.

#### Removed

- Tool execution modes `:blocking_io`, `:cpu_bound`, and `:external_process`.
- `Runtime#blocking_io`, `blocking_io_pool_size`, and
  `blocking_io_queue_size`.
- Caller-facing `OffloadPool::PendingOperation` and
  `PendingOperation#blocking_wait`; asynchronous Phronomy APIs use `Task` as the
  completion contract.
- Waiter-local `cancellation_token:` from `PendingOperation#blocking_wait`.
  Operation-wide cancellation remains on `OffloadPool#submit(cancellation_token:)`.


### EventLoop-first runtime cleanup

#### Added

- Event-driven Agent-as-Tool completion: child Agents now run through their own
  Agent FSMSession and settle the parent ToolInvocation through a completion
  event without holding a OffloadPool worker while waiting.
- Architecture regression coverage for the production Thread/Fiber boundary,
  test-only API separation, current concurrency documentation, and Agent-as-Tool
  pool-starvation behavior.

#### Changed

- `FSMSession + EventLoop` is the single framework control plane for Agent,
  Workflow, ToolInvocation, and MultiAgent lifecycle coordination.
- `Task` is a completion handle only; it does not execute work.
- `execution_mode :cooperative` now means short EventLoop-safe synchronous work,
  or a specialized Tool that starts another Phronomy asynchronous lifecycle and
  returns a completion handle immediately.
- `Tool#call_async` for ordinary cooperative Tools no longer consumes a
  OffloadPool worker. `:offloaded` remains the worker-pool route.
- Framework-owned short in-memory Tools (TeamCoordinator queue controls and
  SharedState store access) explicitly declare
  `execution_mode :cooperative` instead of using the blocking-I/O default.
- MultiAgent fan-out uses a FanOut FSMSession rather than per-child OS Threads.
- `TimerQueue` is driven by EventLoop and owns no Thread.
- Eval support is test infrastructure under `Phronomy::Testing::Eval` and is no
  longer part of the product API compatibility snapshot or README feature set.
- The `dispatch_parallel` regression benchmark now uses thread-free fake child
  completion so it measures FanOut/EventLoop overhead rather than fake Thread
  creation. Its separate CancellationToken contention benchmark intentionally
  continues to use application Threads.

#### Removed

- Active runtime-backend/scheduler documentation for the removed
  `Runtime#spawn`, TaskGroup, Thread/Fiber/Immediate Task backends, and
  configurable runtime backends.
- Product-facing Eval design documentation.

### Agent Context / Knowledge cleanup

#### Added

- Journal-backed persistent Agent Knowledge via creation-time `knowledge:` and
  post-creation `Agent#add_knowledge`.
- `Agent#clear_knowledge!` for logical Knowledge invalidation without deleting
  append-only Journal history.
- ADR-013, defining persistent Knowledge as optional Context candidates selected
  through the Manifest-first Context Policy pipeline.

#### Changed

- Persistent Knowledge and `before_llm_input` segment candidates now participate
  in Context Policy and token-budget selection instead of being injected as
  mandatory system context.
- `clear_transcript!`, `clear_knowledge!`, and `reset_context!` now have distinct
  transcript/Knowledge lifecycle semantics.
- Active Context tests, integration fixtures, benchmarks, mutation subjects,
  design documents, and API snapshots now describe the canonical
  Journal -> Selection::Candidate -> Context Policy -> Manifest architecture.

#### Removed

- `Phronomy::KnowledgeSource`, `Knowledge::Base`, `StaticKnowledge`, and
  `EntityKnowledge`.
- `static_knowledge*`, `add_knowledge_source`, `instance_knowledge_chunks`,
  `Knowledge#static?`, `StaticKnowledge#source`, and the class-level static
  Knowledge cache/fetch abstraction.
- `Agent#clear_memory!` and `AgentRoot#memory_generation`.
- Remaining no-op ContextVersionCache tests, fake legacy-import Context tests,
  obsolete Memory/context integration helpers, legacy `:llm_message` benchmark
  categories, and stale Agent `messages:` test-double signatures.

### Phase 3 cleanup

#### Changed

- Active documentation, compatibility snapshots, benchmarks, integration fixtures,
  and mutation targets now describe the Manifest-first Context architecture.
- The Context benchmark now measures `Agent::ContextAssembler` and
  `ContextPolicies::Default` instead of the removed legacy Assembler.
- ADR-011 is marked Superseded by ADR-012; its historical analysis is retained.

#### Removed

- Remaining active compatibility references to `context_overhead`,
  `LlmContextWindow::Assembler`, `ContextVersionCache`, Tool
  `on_error :return_empty`, `force_kill:`, `runtime_backend :cooperative`,
  the `Runtime.instance=` setter, tools-splat registration, and wall-clock
  `CancellationToken.new(deadline:)`.
- Obsolete legacy Assembler / ContextVersionCache executable specs.

### Documentation

- Reduced `README.md` to the project entry point and moved long-form setup,
  feature stability, runtime/concurrency, and migration guidance into focused
  documents under `docs/`.
- Archived changelog history for 0.14.0 and earlier in
  `docs/changelog/0.14-and-earlier.md`; `CHANGELOG.md` now carries Unreleased
  work and the most recent release history.


---

## [0.16.0] - 2026-08-08

### Added

- Stateful Agent identity and persistence:
  - Every concrete Agent definition declares a stable `agent_definition id:, version:`.
  - Every Agent instance has a stable `agent_id`.
  - `Agent::Base.create` creates a persistent Agent instance.
  - `Agent::Base.load` restores an Agent from a shared Persistence backend.
  - `Agent#agent_root`, `#transcript`, `#clear_transcript!`, `#clear_memory!`,
    `#reset_context!`, `#close!`, and `#purge!` provide explicit state lifecycle operations.

- Persistence-backed Agent execution state:
  - Agent executions have stable `execution_id` values and are persisted separately from the owning Agent.
  - Suspended approval executions remain represented in Persistence.
  - Resuming after process loss still requires future durable activation rehydration support.

- Canonical Complete Execution Log:
  - Phronomy records observed logical execution facts in an append-only Agent Journal.
  - Provider assistant responses preserve assistant content and all Tool Calls as one logical assistant message.
  - Raw Tool return values and the Tool-role messages sent back to the LLM are represented as separate execution facts.

- Per-LLM-call canonical Manifests:
  - Each LLM Call is assembled from a canonical Manifest.
  - The Manifest records the logical input selected for that specific LLM Call.
  - Runtime RubyLLM messages are materialized from the Manifest rather than treated as the source of truth.

- Context Policy domain:
  - Context candidates are selected from canonical history without deleting the underlying Journal.
  - Tool Call / Tool message protocol dependencies are selected atomically.
  - Required context is validated independently from optional historical context.
  - `ContextBudgetExceededError` is raised when required context cannot fit in the available model budget.

- Context import for stateful Agents:
  - Existing user / assistant / Tool history can be supplied through Agent creation context.
  - Imported assistant messages retain their original logical message boundary and Tool Calls.
  - Invalid Tool protocol histories are rejected instead of being guessed or repaired.

- `Workflow#signal(thread_id:, event:, payload:)` for FIFO delivery to a live
  Workflow FSMSession.
- Workflow transition `action:` callbacks, executed after source exit callbacks
  and before target entry callbacks. Actions may accept `(context)` or
  `(context, event)` and may return a replacement Workflow context.
- `InvalidAsyncWorkflowActionError` and
  `InvalidAsyncTransitionActionError`. Transition actions may start async work,
  but returning a `Phronomy::Task` is rejected rather than implicitly awaited.
- Symmetric Agent `on_event:` support for `invoke_async` and `stream_async`;
  streaming differs only by adding `:token` events.
- `Agent#approve_async` and `Agent::Base.approve_async` resume a suspended
  AgentInvocation without blocking the caller and return a `Phronomy::Task`.
- Streaming invocations resumed through `approve_async` continue to deliver
  terminal stream events on the Runtime-owned EventLoop thread.
- `Phronomy::Metrics.snapshot` now reports `event_loop_queue_depth` and
  `event_loop_queue_max_depth`.
- EventLoop emits a rate-limited warning when its shared event queue reaches
  1,000 pending entries. Events are observed only; they are not dropped.

### Changed

- Agent instances are now always stateful and Persistence-backed.

- Conversation history ownership has moved from the caller to the Agent:
  callers no longer need to pass the previous `messages` array back on every invocation.
  Completed invocation results may still expose `result[:messages]` as a materialized
  transcript projection.

- `agent_definition id:, version:` is required for concrete Agent definitions.
  Loading persisted Agent state validates the stored definition identity and version
  against the runtime Agent class.

- Context-window management is now Manifest-first:
  canonical Agent history is retained in the Journal while each LLM Call receives
  only the context selected for its Manifest.

- Context pruning no longer means deleting or mutating historical Agent messages.
  Context Policy omission affects only the current LLM Call input.

- Tool execution results and Tool protocol messages are no longer treated as the
  same value. The raw Tool return value is retained as an execution fact while the
  exact Tool-role message remains independently available for LLM context assembly.

- `thread_id` is an execution/correlation identifier rather than the owner of
  conversation state. Persistent Agent identity is defined by `agent_id`.

- `context_overhead` is retained only for the legacy `build_context` path.
  Manifest-first context assembly accounts for actual mandatory context instead of
  reserving this value as Tool/system-prompt overhead.

- Phronomy now requires `ruby_llm >= 1.15, < 2` so Provider assistant messages can
  be captured before Agent-owned Tool execution begins.

- Refactor: `Agent::AsyncEventApi` is now the single implementation of
  `invoke`, `invoke_async`, `stream`, `stream_async`, and their session
  lifecycle helpers (`_start_invocation`, `_handle_agent_completion`,
  `_register_tool_invocation_session`, `_start_approval_resume`). The
  duplicate definitions in `Agent::Base` have been removed. No public
  behavior change is intended.
- Remove `faraday` and `event_stream_parser` from gemspec declared
  dependencies; both are transitive dependencies of `ruby_llm` and are
  not used directly by phronomy.
- `Workflow#invoke`, `#invoke_async`, and `#stream` now share context
  preparation, StateStore load/save, EventLoop registration, and FSMSession
  execution.
- Workflow entry and transition action return values use the same
  `set_graph_metadata` context protocol as FSMSession, including duck-typed
  context replacements.
- Agent terminal outcomes are delivered to `on_event` before the returned Task
  is settled. `Task#on_complete`, `wait_result`, and cancellation remain active.
- Mapping Agent events to Workflow events, correlation, stale-event handling,
  result persistence, and external Task cancellation are application concerns.
- LLM transport timeout, transient-error retry, backoff, and jitter are delegated
  to RubyLLM or another configured LLM adapter. Phronomy only translates the
  adapter's final provider error.
- Agent execution now creates exactly one AgentInvocation session per call.
- Parallel Tool mode dispatches the complete authorized ToolCall batch; Runtime's
  bounded workers and queues remain the coarse process-protection boundary.
- Caller-provided deadline and cancellation-token propagation is unchanged.

### Removed

- Caller-managed `messages:` continuation from the Agent invocation API.
  Stateful Agent history is now obtained from the Agent's persisted Journal.

- `Agent::Base#trim_messages` and the legacy Agent-level message-trimming model.
  Context selection is performed by the Context Policy / Manifest assembly path.

- The assumption that `build_context` and the legacy `LlmContextWindow::Assembler`
  are the long-term single authority for LLM input. ADR-012 defines the replacement
  Journal / Context Policy / Manifest architecture.

- Implicit awaiting of Task-returning Workflow/Agent/Tool entry actions and the
  Workflow `action_timeout:` DSL. Entry actions are synchronous RTC callbacks.
- The duplicate caller-thread `WorkflowRunner#run_workflow` execution path.
- Agent-wide automatic replay: `Agent::Base.retry_policy` and the `Retryable`
  concern. A failed AgentInvocation is no longer started again by Phronomy.
- Agent-class `invoke_timeout`. Callers that need a root deadline should pass an
  `InvocationContext` with `deadline:` or `cancellation_token:`.
- Phronomy LLM operation timeout `config[:llm_timeout]`; configure RubyLLM's
  `request_timeout` instead.
- Generic Tool retry DSL (`retry_on`, `retry_policies`) and
  `config[:tool_timeout]`; Tool/client implementations own their transport policy.
- `max_parallel_tools` from Agent, AgentInvocation, ParallelToolChat, and
  InvocationContext.
- Unused `InvocationContext#provider_limits`.
- `Configuration#stream_queue_max_size`, which no longer affected the
  Runtime-owned EventLoop streaming path.

### Fixed

- `Agent#approve` now rejects EventLoop re-entry instead of synchronously waiting
  for work that can only be dispatched by that same EventLoop.
