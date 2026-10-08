# Execution abstraction revision (local review candidate, 2026-09-29)

This candidate supersedes the unapplied Results split. It is based on main
653e255a, with the earlier execution-boundary prototype included. It is not a
record of application to main. The historical D02 reports describe their original
revisions; the control ownership decision below supersedes them for this candidate.

## Responsibilities

| Owner | Owns | Consumers should know |
|---|---|---|
| Execution Contracts (G58, B5) | Context, TaskResult/Outcome, cancellation/deadline values, shared errors, neutral scope/result implementation | Public inputs, result handles and errors |
| Execution Services (G59, B4) | Fan-out, child control lifetime, invocation admission checks, completion adaptation, worker submission and deadline registration | Start/observe APIs and domain value/error policies |
| Engine Internals (G14, B5) | Runtime resources, EventLoop, FSMSession | Only runner/lifecycle/composition owners connect here |
| Engine Concurrency (G61, B5) | Pools and queues | Engine supplies scheduling and wait-policy context |

Bands are visual organization, not a dependency order. Backend Contracts remain
in B5. `execution_contract/errors`, `execution_result` and
`execution_result/concurrency` are removed. Their neutral implementation is
integrated into the existing `execution_contract` and its `concurrency` child.
M79/M80/M81 and G60 are retired. TaskResult is not returned to Services: doing so
would recreate Engine→Services. The two contract directories remain mutually
referencing within G58; the design does not claim zero cycles or pure declarations.

## Actual hiding, beyond renaming dependency hubs

| Consumer | Previous knowledge | Current entry point |
|---|---|---|
| Agent::ExecutionCoordinator | Extracted context scope, checked open/cancelled state, selected scope error | InvocationControls.attach + check_start!; Agent still owns admission and its result production |
| MultiAgent::Orchestrator | Called Execution's private fan-out, constructed OperationBinding, linked tokens, selected context, closed subscriptions | Execution.run_async(max_concurrency:) + start_child; supplies child invocation |
| Tools::Agent / generated subagent tools | Created deferred result and relayed completion/failure callbacks | AsyncOperation.call/capture; supplies output/error policy |
| Agent::ToolBinding | Called TaskResult.__map_completion, a special internal composition path | AsyncOperation.map; supplies filters |
| Workflow builder (earlier included change) | Used FSM's finish vocabulary | Workflow::Completion; runner translates to FSM |

InvocationControls extends the existing service helper and absorbs the removed
OperationBinding's lifetime logic. It is not a pass-through factory that still
forces callers to manage cleanup. AsyncOperation encapsulates notification
multiplicity, startup/transformation failure, and physical completion. Domain
consumers still legitimately depend on TaskResult return types and cancellation
inputs; hiding those via aliases would not improve the abstraction.

ExecutionCoordinator, WorkflowRunner and durable reconciliation coordinators
remain result producers. Their lifecycle, registry and terminal policy code has
not all been turned into a generic facade. The public user-facing async APIs and
backend contracts retain their namespaces.

## Investigation heuristic

Detect each M0→M1, M1→M2, M0→M2 triangle in the complete Ruby + RBS graph.
Prioritize adjacent descending display bands, then other descending bands, then
all remaining graph triangles. Keep sidebar modules and visually hidden arrows.
Do not remove edges or make a triangle a CI violation solely on that basis.

For M0's direct M2 usage, inspect its actual source operation:

- Internal detail: Orchestrator linked child tokens and closed subscriptions;
  Execution now owns this through start_child.
- Connection: a runner registers its session with Runtime; this can belong to
  that runner. Move it only if its current owner mixes unrelated responsibilities.
- Shared/public contract: AsyncClient returns TaskResult and callers handle its
  result. Keep the declared RBS dependency instead of erasing the type.

Multiple M1 paths may identify the same direct edge. Reports include both the
triangle count and the number of distinct M0→M2 pairs. RBS-only direct edges are
marked, not automatically accepted. Directory aggregation can combine different
classes/functions, so a graph path is not proof of a call chain. Dynamic dispatch
can also leak details without any constant-reference triangle.

`dependency_triangles.json` preserves all three edges' source evidence;
`dependency_triangles.csv` is the review queue. Entries start as unreviewed.
A separate narrow AST regression gate rejects the already-corrected private
scope methods and selected consumers' manual result settlement. It does not
purport to detect every possible abstraction leak.

## Compatibility and verification scope

Execution.run/run_async accept additive max_concurrency. No new backend methods
are required from application authors. The included earlier candidate removes
InvocationContext#effective_timeout_token/#effective_cancellation_token and the
internal Deadline#attach_to, CancellationScope, old FSM vocabulary ownership.
This revision removes internal OperationBinding and TaskResult.__map_completion.
There are no backward aliases that point neutral contracts back at services.

Tests cover bounded admission, cancellation before queued start, explicit child
context identity, cleanup after completion/start failure, duplicate callback
notifications, original error identity, recovery errors, and physical completion.
Existing Agent, Tool, Workflow, persistence/recovery and async tests remain gates.
The delivered evidence report records actual execution results and limitations.
