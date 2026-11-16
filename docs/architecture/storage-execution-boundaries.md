# Storage execution boundaries after P4

Domain owners schedule their persistence work through Execution and retain the
transaction, result application and uncertain-outcome policy. The raw Storage
client separately schedules an application-supplied backend transaction.

For example, an Agent terminal outcome is submitted through its execution
environment and committed by the Agent operation. The operation decides whether
an uncertain response requires readback. Storage does not wrap that operation in
another transaction or decide that the commit succeeded.

The following inventory contains 14 submission calls in six source files. It
does not count every durable operation in the framework. The former separate
Provider/Tool dispatch reconciliation submissions are absent; Agent change
reconciliation belongs to `ExecutionChange#perform_once`.

| Owner / source under `lib/phronomy/` | Unit | Submission receiver / result application |
|---|---|---|
| `agent/execution/execution_coordinator.rb` | Provider dispatch preparation | Agent environment; ProviderDispatchPreparationReady |
| same | Tool dispatch preparation | Agent environment; ToolDispatchPreparationReady |
| same | Initial invocation preparation | Agent environment; InitialPreparationReady |
| same | Recovery of initial preparation | Agent environment; InitialPreparationRecoveryReady |
| same | Approval resume commit | Agent environment; ResumeCommitReady and admission handling |
| same | Terminal outcome commit | Agent environment; TerminalCommitReady and commit/readback policy |
| `agent/execution/exact_execution.rb` | Exact execution read, recovery and materialization | Agent environment; observer completion / owner installation |
| same | Exact execution reconciliation and result materialization | Agent environment; observer completion |
| `agent/recovery/recovery_coordinator/resolution.rb` | Resolution preparation, save/readback and materialization | Agent environment; ResolveReady before live-state application |
| `workflow/execution/workflow_runner.rb` | Durable snapshot load | Workflow environment; load-ready command |
| same | Terminal snapshot save and uncertain-result readback | Workflow environment; terminal persistence delivery |
| `multi_agent/durable_subagent_coordinator.rb` | Reserved child load/create/recovery and input materialization | `Execution.submit`; exact child execution observer |
| `multi_agent/team_coordinator.rb` | External cancellation's durable transition | MultiAgent environment; cancellation/readback policy |
| same | Durable Team Tool operation and reconciliation | `Execution.submit`; Tool completion/error policy |

Every listed call uses `on_full: :raise` without adding a submission timeout or
cancellation token. An execution environment forwards its owning Runtime to
Execution; the Engine binding selects that Runtime's pool. Direct submissions
use the configured Execution binding. The unused private
`Storage::AsyncClient.submit` forwarding helper is removed.

The three MultiAgent sites are included because they perform the same kind of
durable work as Agent and Workflow. They do not introduce a new shared domain
transaction or move Team rules into Storage.

## Boundaries deliberately retained

An execution boundary follows the operation's owner, rather than whether the
operation happens to perform I/O. Domain-specific callbacks and failure policies
therefore remain outside the raw transaction client.

For example, Tool authorization and an Agent approval listener both run work
asynchronously, but neither becomes a Storage transaction merely because a
Tool or listener may consult a database.

| Existing boundary | Reason |
|---|---|
| Agent approval listener dispatch | Application callback; not a storage operation |
| ToolExecutor / ToolInvocation authorization pool | Tool execution and authorization; their token/timeout contracts remain distinct |
| LLM / VectorStore / Embeddings clients | Already own their feature-specific execution boundaries |
| Tracing and evaluation scorer | Telemetry / scoring work, not storage |
| MCP cleanup pool | Transport cleanup, not storage |
| Synchronous Agent load/create, domain repository methods and recovery helpers | Stay synchronous; their existing callers own the offload boundary |

Domain submission adds no `backend.transaction` call. Public
`Storage::AsyncClient#transaction_async` opens one raw transaction on the worker
and yields its view. A durable domain unit may already contain transactions,
reconciliation reads and materialization in a defined order. An extra outer
transaction would change commit visibility, connection lifetime and
uncertain-result behavior.

Runtime tests cover original TaskResult identity, single submission, rollback,
nested savepoints, scope lifetime, cancellation/timeout and preserved failures.
Existing Agent/Workflow/Team tests continue to exercise admission, uncertain
commits and live-state application. Real SQLite verification complements these
tests; static dependency lines alone do not prove transaction behavior.
