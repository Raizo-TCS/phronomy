# Execution dependency ownership

Use the highest existing operation that expresses the caller's responsibility.
A facade is useful when it owns real coordination, not just because it reduces
arrows. These cases distinguish shared contracts from executable machinery.

| Caller / operation | Dependency after this change | Decision |
|---|---|---|
| ToolBinding result filter | TaskResult private completion mapping | Remove duplicate physical-completion handling; source completion alone must not finish the filtered result |
| Tracing span finish | Blocking.call_async | Generic default-pool work; observe rejection in the returned result |
| Approval listener dispatch | Blocking.call_async | Generic default-pool work; log admission and later callback errors |
| Agent/Workflow synchronous entry guard | Runtime.in_event_loop_context? | Query context without creating Runtime |
| Prompt parser, Runnable users | Execution Contracts | Public callable/value contract, not pool internals |
| Agent lifecycle/state, capability and journal input markers | Execution Contracts | Methodless classification; preserve direct include and validation |
| Tool and async-client RBS token/result references | Execution Contracts / Execution Services | Keep real public type use in the graph; do not invent a domain facade for a token |
| LLM, VectorStore, Embeddings and Storage AsyncClients | Contracts + TaskResult + Runtime/pools | Intended bridge; keep specialized submission, token and admission rules |
| Agent ExecutionCoordinator / MultiAgent binding | Concurrency operation binding | Own cancellation/deadline scope across an operation; generic Blocking is not equivalent |
| Agent and Workflow runners / execution registries | Runtime, FSM session and control delivery | Framework connection and single-writer ownership; retain these explicit dependencies |
| Engine worker pool | TaskResult and execution errors | Produces shared results; the service/Engine relationship is not acyclic |

The full dependency graph still includes references through shared error classes,
markers and RBS. Moving their source owners changes the interpretation of the
old Engine fan-in; it does not remove their actual use. The architecture gate
enforces Contracts-to-Contracts/Common only and rejects domain/backend/client
dependencies from Services or Engine. Layout is independent of those rules.

See [ADR-063](../decisions/063-execution-contracts-and-services.md) for the source
layout, behavior change and compatibility boundary.
