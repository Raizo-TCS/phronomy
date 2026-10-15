# Error API review (DX05-A / EA01–EA06)

Applications should branch on the meaning of a failed public operation without
knowing its backend or reconstructing it from an error message. The review uses
core `5b9d1047cc1351a935a7871ae7705c65166ea971` and examples
`5f4d58dc9432a84cb4421d3cc7dc2da92aee3c72` as its baseline.

The original DX05-A change implements the error API part of the follow-up design. DX05-B
(notification wiring), C (review result collection), D (`task_state`) and E
(Agent scope/unload) remain separate work. Their proposed APIs are not provided
by this patch. EA06's integration with D/E cannot be accepted before those APIs
exist. Live PostgreSQL, Redis, provider services and complete Rails execution
are separate acceptance gates; see the delivery's verification record.

The subsequent, unreleased DX05-D change now provides `task_state`; see
[its design and acceptance boundary](dx05-workflow-task-state.md).
Its error decision is included below. Agent scope/unload (DX05-E) remains
separate work. This does not change the historical DX05-A baseline above.

## Rules and ownership

* The owning Contract defines the failure category. A class is added only when
  a caller has a distinct, stable decision to make. Detailed reasons use an
  optional String `code`; they do not imply retry safety, rollback or worker exit.
* H00 owns the base Error and generic diagnostic projection/reconstruction.
  It does not identify Agents, choose a retry policy or interpret domain codes.
* C07 Persistence and C12 Storage retain independent error hierarchies.
  StorageBoundary translates only its existing known categories with an explicit
  cause. A storage reason is not automatically a persistence reason.
* C13 transports the exception. It does not classify Agent, Team or Workflow
  failures. `:cancelled` and a failed task carrying CancellationError remain
  different facts. Partial `outcomes` remain on their existing execution errors.
* ArgumentError/TypeError describe Ruby/API input or mapping errors where already
  documented. NotImplementedError marks an abstract extension point; it is not
  converted into a provider failure.
* Existing message-only constructors remain valid. Seven public specialized
  constructors now accept optional `code:` without changing their attributes.
  New target-absence/busy constructors own fixed codes and object identities.
* Sync/async operation failures keep their category, reason and original cause.
  Existing entry-time validation and submission rejection may still raise before
  a TaskResult is returned. A TaskResult is not a promise of rollback.

## Operation decisions and acceptance

Each row names the operation family reviewed, its observed channel, the retained
asymmetry and the action. This is an evaluation of these operations, not a claim
that every possible backend failure has been injected.

| Owner | Public operations / failure meaning / channel | Decision and application effect | Acceptance evidence |
|---|---|---|---|
| C01 | TeamCoordinator.create/load: root absence, duplicate identity, uncertain create; direct raise | Add TeamNotFoundError only around the requested root load. Duplicate create retains Persistence conflict: a separate AlreadyExists class adds no necessary recovery choice here. A failed create readback keeps the original failure. | team_coordinator_spec; durable_coordination_spec |
| C01 | invoke/admission, TeamExecutionRepository.create_active/save/assert_idle!: active Team run | TeamBusyError with team_id and team.busy replaces AgentBusyError only for Team ownership. Child-Agent failures retain their own classes. No AgentBusy alias or inheritance. | execution_constraint_translation_spec; shared SQL coordination contract |
| C01 | HandoffRunner.invoke/cancel, Orchestrator fan-out, operation rejection | Retain ConfigurationError, HandoffError, StateConflictError, recovery requirements and on_error policy. Missing retained children are not missing Teams. Readback reconciliation may itself fail and does not prove absence. OperationRejected stays private; public code team.enqueue_after_finalize is unchanged. | durable_coordination_spec; integration/team_coordinator_spec; SQL reason diagnostics |
| C02 | Workflow definition/action, WorkflowContext writes, state CAS, waiting/resume | Retain ConfigurationError, WorkflowContextOwnershipError, WorkflowAsyncActionError and persistence conflict. Workflow has no equivalent target-root load API to justify another NotFound class. DX05-D adds WorkflowTaskResumeError with workflow.task_resume_unsupported only for unsupported restoration of a task-state phase, before any start side effect. Start/source/apply failures keep their original errors, and task cancellation remains distinct from a failed CancellationError. Agent scope is separate. | workflow and execution unit/integration suites; task_state_spec; shared SQL task-state contract (live PostgreSQL acceptance pending) |
| C03 | GeneratorVerifier.invoke; schema-qualified confidence decision | Agent owns OutputError; Generation records output_failed with its diagnostic; GeneratorVerifier::UnacceptedResultError carries Result and an optional code. CleanupError retains cleanup and primary failures. See generator-verifier-lifecycle-result.md. | generator_verifier specs; error_api_diagnostics_spec |
| C04 | Base.load, create/get, invoke/resume/purge | Add AgentNotFoundError only at the requested root. Journal/content/execution absence remains persistence failure. Preserve foreign AgentNotFound identity. AlreadyExists/Busy/Purged, uncertain purge and recovery-required retain their meaning. | error_api_boundaries_spec; Agent lifecycle/recovery suites |
| C04 | stream listener policy; result/failure persistence | StreamCallbackError keeps event_type/original_error/result, with optional code. Listener :fail_task versus :log_and_continue remains explicit; no unconditional callback swallowing. | stream_callback_error_policy_spec; error_api_diagnostics_spec |
| C05 | Assembly.prepare and policy invocation; plan/budget validation | Keep BudgetExceededError and ManifestError. Reuse C15 public trace_with, metadata only; a finish failure cannot mask policy failure or export the returned context. | error_api_boundaries_spec; Context suites |
| C06 | Tool.call / native async operation; schema, execution, async handle validity | Keep ToolError class; supply tool.invalid_arguments / tool.execution_failed / tool.invalid_async_result at owned conversion sites. Explicit async cause fixes delayed-failure information loss. Existing ToolError/cancellation pass through unchanged. :suppress survives logger failure. | tool/async_operation_spec; tool/base_spec; schema_error_spec |
| C07 | StorageBoundary, transaction, SaveOutcome, SnapshotComparison | Retain known-category mapping and original cause. Unknown I/O/application failures pass through. Keep committed/not_committed/unknown separately from exception class; no code-based reconciliation. | storage_boundary_spec; failure_contract_spec; snapshot_comparison_spec; SQL suites |
| C08 | fetch, fetch_text, fetch_json and content identity | Invalid requested JSON is IntegrityError with content.invalid_json and original ParserError; invalid UTF-8 is content.invalid_encoding. Raw fetch failures pass through; no dependency on OutputParser. Requesting JSON for plain text is also invalid representation, not proof of physical corruption. | error_api_boundaries_spec; content conformance; SQLite |
| C09 | LLM complete/stream, request/result checks, RubyLLM conversion | Authentication/RateLimit remain TransportError children; ContextLength and InvalidResult remain separate. The RubyLLM backend also maps identified Faraday TimeoutError/ConnectionFailed to TransportError with the original cause chain. Unknown exceptions, cancellation/deadlines and callbacks (including same-class Faraday failures) retain identity. Classification does not imply retry safety. | LLMAdapter suites; transport_error unit and real-HTTP integration contracts |
| C10 | VectorStore add/search/remove/clear/size and AsyncClient | Keep InvalidResultError for invalid response and driver communication errors unchanged. Driver-specific transaction/effect uncertainty is not normalized without a backend-specific contract. No universal VectorStore TransportError or sibling-contract borrowing. | VectorStore and async-client suites; live PG/Redis pending |
| C11 | Embeddings.embed / AsyncClient; RubyLLM errors | Owner-local AuthenticationError and RateLimitError remain under TransportError. Other RubyLLM errors and identified Faraday TimeoutError/ConnectionFailed map to TransportError in the concrete backend, preserving causes. Arbitrary I/O failures, cancellation/deadlines and programming errors are not guessed to be SDK failures. | error_api_boundaries_spec; embeddings/async_client_spec; transport_error unit and real-HTTP integration contracts |
| C12 | Records.read/fetch, conditions/unique constraints, streams/blobs, atomic views | Keep nil read versus raising fetch; preserve condition/resource/constraint. Add optional code to specialized constructors; SPI 2 and storage format unchanged. No Agent or Persistence semantics in the backend. | storage SPI snapshot; backend conformance; SQLite |
| C13 | TaskResult completion, map/flat_map/all_settled, wait/timeout/cancel | Transport errors unchanged. Observer failure leaves settled result intact and continues later observers even if logging fails. Transformation failure settles the derived task. Outcome attributes and physical completion remain separate. | task_result_spec; error_api_boundaries_spec; async composition suites |
| C15 | Base.trace, trace_with, OpenTelemetry.trace, Automatic | Explicit tracing propagates start/finish-only failure. After a primary business failure finish is attempted once and secondary report failure is suppressed. No finish after start failure. OpenTelemetry keeps with_span context. Automatic retains best-effort observation policy; Langfuse keeps its adapter-specific network suppression. | tracing/base_spec; open_telemetry_tracer_spec; automatic and extension specs |
| C16 | Filter.call/block!, PromptInjectionFilter | Keep explicit FilterBlockError and filter attribute; add optional constructor code. Implementation errors are not transformed into policy refusal. No unnecessary common rejection hierarchy. | filter specs; error_api_diagnostics_spec |
| C17 | JsonParser.parse, StructuredParser.parse | Keep ParseError for JSON and documented ArgumentError/TypeError schema-instantiation rejection. Other schema bugs pass through. User schemas should raise domain-specific errors when they must not be treated as mapping rejection. No blanket StandardError rescue added. | output_parser specs; schema integration |
| M91 | OrderedEventDelivery.publish/open/drain | ClosedError/OverflowError now inherit Phronomy::Error and report delivery.closed / delivery.capacity_exceeded. StandardError rescue still works; Phronomy::Error rescue now includes them. Reporting failure cannot replace an application error. No automatic resend. | ordered_event_delivery specs; error_api_boundaries_spec |
| I05/I06/I07/I09 | Concrete binding, AsyncClients, runtime admission/shutdown | Preserve backend-specific failures and execution admission/timeout categories. No new reverse references into domain contracts. | architecture gate; backend/execution integration |
| Other concrete helpers | Documents loaders, tools, evaluation and configuration | Preserve documented external operation errors and configuration checks; do not manufacture an application-wide ErrorTranslator. Generic Tool conversion applies when called through its public contract. | concrete tool/document/evaluation suites |

## Diagnostic format and recovery

Top-level `class`, `message` and optional `code` remain unchanged. An optional
`cause` object transports the same neutral fields. New cause data is bounded to
three ancestors and 2,048 characters per field. A further cause is represented
by `{ "truncated": true }`; an oversized code is omitted, never shortened into
another valid-looking code. Old top-level message behavior is unchanged.
Backtraces, arbitrary exception attributes and live objects are not serialized.

Agent and Team recovery use the same H00 decoder. It constructs only generic
Phronomy::Error values, including their optional causes, and never constantizes
saved names. Unknown/nil codes are retained. A restored cause is diagnostic data,
not the original exception object or its domain-specific attributes. Applications
may inspect `error.cause&.code` without depending on a storage exception class.
The live exception still retains its exact original cause.

## Migration and before/after use

Before, a broad Persistence/Storage NotFound rescue could mistake a broken
transcript for a missing Agent. After, limit creation to the requested identity:

```ruby
begin
  agent = ConversationAgent.load(agent_id, persistence: store)
rescue Phronomy::AgentNotFoundError => error
  raise unless error.agent_id == agent_id.to_s
  agent = ConversationAgent.create(agent_id: agent_id, persistence: store)
end
# A later transcript failure is not handled as Agent absence.
messages = PhronomyExamples::TranscriptMessages.read(agent)
```

Before, an application handled a busy Team by rescuing AgentBusyError. After:

```ruby
begin
  team.invoke(input)
rescue Phronomy::MultiAgent::TeamBusyError => error
  # Application decides whether to expose an existing run or defer new work.
  show_active_team(error.team_id)
end
```

Before, Embeddings::TransportError alone required SDK knowledge to distinguish
credentials and quota. After, both remain catchable through TransportError:

```ruby
begin
  vector = embeddings.embed(text)
rescue Phronomy::Embeddings::AuthenticationError
  request_credentials
rescue Phronomy::Embeddings::RateLimitError
  display_limit
rescue Phronomy::Embeddings::TransportError => error
  report_provider_failure(error)
end
```

These are application choices, not core-provided UI or automatic retry helpers.
For Tool failures the application code need not change: `error.cause` now works
for late async failures too. New reason codes are additive; custom ToolError
instances pass through with their original nil/unknown code.

| Existing consumer | Migration / compatibility |
|---|---|
| Persistence::NotFoundError rescue around Agent/Team load | Still catches the new subclass; narrow it to the domain type and target ID for create-on-absence |
| Storage::NotFoundError rescue around Agent load | Already crossed the wrong boundary; update as the examples do |
| AgentBusyError rescue for Team's own admission | Change to MultiAgent::TeamBusyError; this is an intentional rescue-set change |
| JSON::ParserError rescue around content.fetch_json | Change to ContentStore::IntegrityError and inspect code; original ParserError is cause |
| Embeddings::TransportError rescue | Still catches both new subclasses |
| Phronomy::Error rescue around optional delivery | Now includes ClosedError/OverflowError; evaluate the application's handling |
| Exact equality of saved diagnostic hashes | Allow/test the optional cause object. Existing keys/codes and old JSON remain readable |
| Error message parsing or class-name constantization | Use public categories/codes for live failures; generic decoded diagnostics for recovery |
| Generic error logger retrying any error | Review separately; code/type does not prove rollback or idempotence |

## Dependency acceptance

No new Contract is introduced. New types live with C01/C04/C11; M91 remains an
optional consumer. C04/C01 specialize C07's absence category using existing
forward dependencies. H00 has no new domain reference. C05 uses C15's public
SPI wrapper rather than a private helper. C09/C10/C11 do not borrow each other's
error types. Ruby and RBS dependency graphs, not just Contract counts, are checked
by the existing architecture tool. See the generated audit for candidate tree
and exact deltas; the separate Contract diagram must describe the candidate as
unmerged until adoption is verified.

### Correction to the earlier Contract count

The baseline and candidate both have **32**, not 30, static Contract pairs.
The previous report omitted the existing RBS-only C01 → C08 references in
`sig/phronomy/multi_agent/store.rbs` (Store/_Records.contents) and C05 → C08
in `sig/phronomy/context.rbs` (Assembly.store). Both name the C08-owned
`_ContentRepository` interface. These are valid forward public-contract
references, not implementation dependencies introduced by this patch.
The candidate diagram restores these two edges and labels the correction.

At directory level the union still has 273 pairs, but two entries change:
M91 integrations → H00 common is added; multi_agent/persistence → agent is
removed because Team admission now owns its BusyError. Equal totals alone
would conceal this responsibility improvement. The 32 Contract pairs are
unchanged and acyclic; Ruby+RBS architecture validation passes.

## Static exception inventory

Ripper inspected 339 Ruby files. The following 63 definitions include base, private and optional-integration types; this is not a count of public APIs. Ruby declarations establish ownership. Existing RBS definitions and new owning-domain signatures are checked together.

| Class | Parent | Declaration |
|---|---|---|
| `Phronomy::AgentAlreadyExistsError` | `Phronomy::Error` | `lib/phronomy/agent/agent_already_exists_error.rb` |
| `Phronomy::AgentBusyError` | `Phronomy::Error` | `lib/phronomy/agent/agent_busy_error.rb` |
| `Phronomy::AgentNotFoundError` | `Phronomy::Persistence::NotFoundError` | `lib/phronomy/agent/agent_not_found_error.rb` |
| `Phronomy::AgentPurgedError` | `Phronomy::Error` | `lib/phronomy/agent/agent_purged_error.rb` |
| `Phronomy::ExecutionRehydrationRequiredError` | `Phronomy::Error` | `lib/phronomy/agent/api/execution_rehydration_required_error.rb` |
| `Phronomy::HandoffError` | `Phronomy::Error` | `lib/phronomy/agent/handoff_error.rb` |
| `Phronomy::Agent::RecoveryCoordinator::ResolutionOutcomeUnknownError` | `Phronomy::Error` | `lib/phronomy/agent/recovery/recovery_coordinator.rb` |
| `Phronomy::StreamCallbackError` | `Phronomy::Error` | `lib/phronomy/agent/stream_callback_error.rb` |
| `Phronomy::ConfigurationError` | `Phronomy::Error` | `lib/phronomy/common/configuration_error.rb` |
| `Phronomy::Error` | `StandardError` | `lib/phronomy/common/error.rb` |
| `Phronomy::ContentStore::IntegrityError` | `Phronomy::Error` | `lib/phronomy/content_store/base.rb` |
| `Phronomy::Context::BudgetExceededError` | `Phronomy::Error` | `lib/phronomy/context/budget_exceeded_error.rb` |
| `Phronomy::Context::ManifestError` | `Phronomy::Error` | `lib/phronomy/context/manifest_error.rb` |
| `Phronomy::Embeddings::AuthenticationError` | `Phronomy::Embeddings::TransportError` | `lib/phronomy/embeddings/authentication_error.rb` |
| `Phronomy::Embeddings::InvalidResultError` | `Phronomy::Error` | `lib/phronomy/embeddings/invalid_result_error.rb` |
| `Phronomy::Embeddings::RateLimitError` | `Phronomy::Embeddings::TransportError` | `lib/phronomy/embeddings/rate_limit_error.rb` |
| `Phronomy::Embeddings::TransportError` | `Phronomy::Error` | `lib/phronomy/embeddings/transport_error.rb` |
| `Phronomy::BackpressureError` | `Phronomy::Error` | `lib/phronomy/execution/backpressure_error.rb` |
| `Phronomy::CancellationError` | `Phronomy::Error` | `lib/phronomy/execution/cancellation_error.rb` |
| `Phronomy::EventLoopReentrancyError` | `Phronomy::Error` | `lib/phronomy/execution/event_loop_reentrancy_error.rb` |
| `Phronomy::ExecutionCancellationError` | `Phronomy::CancellationError` | `lib/phronomy/execution/execution_cancellation_error.rb` |
| `Phronomy::ExecutionTimeoutError` | `Phronomy::TimeoutError` | `lib/phronomy/execution/execution_timeout_error.rb` |
| `Phronomy::InvalidAsyncEntryActionError` | `Phronomy::InvalidAsyncWorkflowActionError` | `lib/phronomy/execution/invalid_async_entry_action_error.rb` |
| `Phronomy::InvalidAsyncTransitionActionError` | `Phronomy::InvalidAsyncWorkflowActionError` | `lib/phronomy/execution/invalid_async_transition_action_error.rb` |
| `Phronomy::InvalidAsyncWorkflowActionError` | `Phronomy::Error` | `lib/phronomy/execution/invalid_async_workflow_action_error.rb` |
| `Phronomy::PoolShutdownError` | `Phronomy::Error` | `lib/phronomy/execution/pool_shutdown_error.rb` |
| `Phronomy::RecursionLimitError` | `Phronomy::Error` | `lib/phronomy/execution/recursion_limit_error.rb` |
| `Phronomy::RuntimeShutdownError` | `Phronomy::Error` | `lib/phronomy/execution/runtime_shutdown_error.rb` |
| `Phronomy::RuntimeShutdownReentrancyError` | `Phronomy::RuntimeShutdownError` | `lib/phronomy/execution/runtime_shutdown_reentrancy_error.rb` |
| `Phronomy::SchedulerReentrancyError` | `Phronomy::EventLoopReentrancyError` | `lib/phronomy/execution/scheduler_reentrancy_error.rb` |
| `Phronomy::TimeoutError` | `Phronomy::Error` | `lib/phronomy/execution/timeout_error.rb` |
| `Phronomy::FilterBlockError` | `Phronomy::Error` | `lib/phronomy/filter/filter_block_error.rb` |
| `Phronomy::GeneratorVerifier::UnacceptedResultError` | `Phronomy::Error` | `lib/phronomy/generation/generator_verifier/unaccepted_result_error.rb` |
| `Phronomy::Integrations::OrderedEventDelivery::ClosedError` | `Phronomy::Error` | `lib/phronomy/integrations/ordered_event_delivery.rb` |
| `Phronomy::Integrations::OrderedEventDelivery::OverflowError` | `Phronomy::Error` | `lib/phronomy/integrations/ordered_event_delivery.rb` |
| `Phronomy::LLMAdapter::AuthenticationError` | `Phronomy::LLMAdapter::TransportError` | `lib/phronomy/llm_adapter/authentication_error.rb` |
| `Phronomy::LLMAdapter::RubyLLM::ToolsRequested` | `StandardError` | `lib/phronomy/llm_adapter/backends/ruby_llm.rb` |
| `Phronomy::LLMAdapter::ContextLengthError` | `Phronomy::Error` | `lib/phronomy/llm_adapter/context_length_error.rb` |
| `Phronomy::LLMAdapter::InvalidResultError` | `Phronomy::Error` | `lib/phronomy/llm_adapter/invalid_result_error.rb` |
| `Phronomy::LLMAdapter::RateLimitError` | `Phronomy::LLMAdapter::TransportError` | `lib/phronomy/llm_adapter/rate_limit_error.rb` |
| `Phronomy::LLMAdapter::TransportError` | `Phronomy::Error` | `lib/phronomy/llm_adapter/transport_error.rb` |
| `Phronomy::MultiAgent::TeamBusyError` | `Phronomy::Error` | `lib/phronomy/multi_agent/team_busy_error.rb` |
| `Phronomy::MultiAgent::TeamCoordinator::OperationRejected` | `Phronomy::ConfigurationError` | `lib/phronomy/multi_agent/team_coordinator.rb` |
| `Phronomy::MultiAgent::TeamNotFoundError` | `Phronomy::Persistence::NotFoundError` | `lib/phronomy/multi_agent/team_not_found_error.rb` |
| `Phronomy::ParseError` | `Phronomy::Error` | `lib/phronomy/output_parser/parse_error.rb` |
| `Phronomy::Persistence::Error` | `Phronomy::Error` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Persistence::ConflictError` | `Phronomy::Persistence::Error` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Persistence::StateConflictError` | `Phronomy::Persistence::ConflictError` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Persistence::NotFoundError` | `Phronomy::Persistence::Error` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Persistence::SerializationError` | `Phronomy::Persistence::Error` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Persistence::UnsupportedBackendError` | `Phronomy::Persistence::Error` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Persistence::TransactionError` | `Phronomy::Persistence::Error` | `lib/phronomy/persistence/errors.rb` |
| `Phronomy::Storage::BlobConflictError` | `Phronomy::Storage::ConflictError` | `lib/phronomy/storage/blob_conflict_error.rb` |
| `Phronomy::Storage::ConditionFailedError` | `Phronomy::Storage::ConflictError` | `lib/phronomy/storage/condition_failed_error.rb` |
| `Phronomy::Storage::ConflictError` | `Phronomy::Error` | `lib/phronomy/storage/conflict_error.rb` |
| `Phronomy::Storage::NotFoundError` | `Phronomy::Error` | `lib/phronomy/storage/not_found_error.rb` |
| `Phronomy::Storage::SerializationError` | `Phronomy::Error` | `lib/phronomy/storage/serialization_error.rb` |
| `Phronomy::Storage::TransactionError` | `Phronomy::Error` | `lib/phronomy/storage/transaction_error.rb` |
| `Phronomy::Storage::UniqueConstraintError` | `Phronomy::Storage::ConflictError` | `lib/phronomy/storage/unique_constraint_error.rb` |
| `Phronomy::Storage::UnsupportedBackendError` | `Phronomy::Error` | `lib/phronomy/storage/unsupported_backend_error.rb` |
| `Phronomy::ToolError` | `Phronomy::Error` | `lib/phronomy/tool/tool_error.rb` |
| `Phronomy::VectorStore::InvalidResultError` | `Phronomy::Error` | `lib/phronomy/vector_store/invalid_result_error.rb` |
| `Phronomy::WorkflowContextOwnershipError` | `Phronomy::Error` | `lib/phronomy/workflow/execution/workflow_context_ownership_error.rb` |
| `Phronomy::WorkflowTaskResumeError` (DX05-D) | `Phronomy::Error` | `lib/phronomy/workflow/execution/workflow_task_resume_error.rb` |
