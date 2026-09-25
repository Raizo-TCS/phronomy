# Storage execution units in P4

The following 16 submission sites delegate to internal
`Storage::AsyncClient.submit(pool:)`. Only submission ownership changes: their
blocks, result callbacks, domain transactions and error/reconciliation policy
remain in their original owners. Each submitted unit still uses the exact
pool selected by the owner, with `on_full: :raise` and no new timeout/token.

| Owner / source under `lib/phronomy/` | Unit | Result application |
|---|---|---|
| `agent/execution/execution_coordinator.rb` | Provider dispatch preparation | ProviderDispatchPreparationReady on EventLoop |
| same | Tool dispatch preparation | ToolDispatchPreparationReady on EventLoop |
| same | Uncertain Provider dispatch reconciliation | ProviderDispatchPreparationReconciliationReady |
| same | Uncertain Tool dispatch reconciliation | ToolDispatchPreparationReconciliationReady |
| same | Initial invocation preparation | InitialPreparationReady |
| same | Recovery of initial preparation | InitialPreparationRecoveryReady |
| same | Approval resume commit | ResumeCommitReady; existing admission handling |
| same | Terminal outcome commit | TerminalCommitReady; existing save/readback and live-state policy |
| `agent/execution/exact_execution.rb` | Exact execution read, recovery and materialization | Original observer completion / owner installation |
| same | Exact execution reconciliation and result materialization | Original observer completion |
| `agent/recovery/recovery_coordinator/resolution.rb` | Resolution preparation, save/readback and materialization | ResolveReady; validate before applying live state |
| `workflow/execution/workflow_runner.rb` | Durable snapshot load | Original load-ready command |
| same | Terminal snapshot save and uncertain-result readback | Original terminal persistence delivery |
| `multi_agent/durable_subagent_coordinator.rb` | Reserved child load/create/recovery and input materialization | Original exact child execution observer |
| `multi_agent/team_coordinator.rb` | External cancellation's durable transition | Existing cancellation/readback policy |
| same | Durable Team Tool operation and reconciliation | Original Tool completion/error policy |

The three MultiAgent sites are included because they perform the same kind of
durable work as Agent and Workflow. They do not introduce a new shared domain
transaction or move Team rules into Storage.

## Boundaries deliberately retained

| Existing boundary | Reason |
|---|---|
| Agent approval listener dispatch | Application callback; not a storage operation |
| ToolExecutor / ToolInvocation authorization pool | Tool execution and authorization; their token/timeout contracts remain distinct |
| LLM / VectorStore / Embeddings clients | Already own their feature-specific execution boundaries |
| Tracing and evaluation scorer | Telemetry / scoring work, not storage |
| MCP cleanup pool | Transport cleanup, not storage |
| Synchronous Agent load/create, domain repository methods and recovery helpers | Stay synchronous; their existing callers own the offload boundary |

Internal submit does not call `backend.transaction`. Public
`Storage::AsyncClient#transaction_async` opens exactly one outer raw transaction
on the worker and yields its view. They are separate entry points because a
durable domain unit may already have transactions, reconciliation reads and
materialization in a defined order. Adding an outer transaction would change
that order's commit visibility, connection lifetime and uncertain-result behavior.

Runtime tests cover original TaskResult identity, single submission, rollback,
nested savepoints, scope lifetime, cancellation/timeout and preserved failures.
Existing Agent/Workflow/Team tests continue to exercise admission, uncertain
commits and live-state application. Real SQLite verification complements these
tests; static dependency lines alone do not prove transaction behavior.
