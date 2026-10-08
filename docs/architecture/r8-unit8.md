# r8 unit 8: C04 Tool child progress and C06 operation boundaries

Contract placement follows ownership of domain meaning, invariants and operations.
C04 owns the lifecycle of a Tool invocation inside an Agent. Calling a Tool does
not transfer that lifecycle to C06. This unit completes the scoped Tool child FSM
separation left by unit 7; it does not certify all of C04 or the overall target.

| Owner | Responsibility |
| --- | --- |
| Agent ToolInvocationTransitions | Child phases, ordered automatic/external transitions, legal event sources and recursion bound |
| Agent ToolInvocationActions / ToolInvocation | Validation/authorization orchestration, approval waiting, dispatch eligibility, outcome application and parent notification |
| Agent ExecutionEnvironment | The original Agent connection for authorization and default Tool submissions, operation supervision and session creation |
| Agent ToolSessionBuilder / PhaseMachineBuilder in runtime_binding | Concrete FSMSession/EventSink construction and state_machines adaptation of Agent-owned rules |
| Tool Operation | Tool execution-mode validity, standard/custom async operation dispatch, completion protocol and result adaptation |
| Tool ToolExecutor | Default cooperative/offloaded Tool operation, using the injected C13 submission protocol |
| Execution / _ExecutionSubmitter | Execution submission and completion semantics; concrete resource selection stays in the supplied connection |

## What changed

ToolInvocationSessionBuilder previously repeated external transitions in both its
event map and state_machines DSL while also constructing sessions and executing
Agent entry operations. The new child policy owns one immutable transition set.
The concrete phase machine and FSMSession source admission read that set. The
existing parent FSM adapter accepts a policy, so no second domain-aware FSM
implementation is introduced. Entry operations remain executable Agent code.

ToolInvocation now requires its owning execution environment for authorization
and execution. It no longer selects Runtime.instance, inspects EventLoop, creates
an ExecutionRegistry connection or selects ToolExecutor. The parent Agent and
recovery already retain the environment from unit 7; the same environment now
supplies Tool child entry operations. Authorization captures immutable command
data before submission. Worker completion delivers an outcome, and serial event
delivery applies live state.

Tool::Operation.call_async is the C06 operation entry for composition-aware
callers. It selects the standard or custom Tool protocol and validates the
execution mode and completion handle. Its submitter must implement C13 submit;
it receives no Agent-specific type. The default offloaded path uses the supplied
connection, while cooperative work executes inline without a worker. Custom
call_async implementations keep their existing keyword signature and config,
return their original handle and continue to own their execution mechanism.
In particular, an override that calls super still uses the existing Base
protocol; this change does not inject hidden Runtime state into overrides.

Tool::Operation.with_result_transform owns the synchronous/custom-async Tool
decoration mechanism formerly embedded in Agent::ToolBinding. Agent still chooses
its configured filters and their meaning. Custom async mapping uses
AsyncOperation.map and preserves physical completion after logical cancellation.
As before, an override that itself calls an already decorated synchronous method
can transform twice; this unit does not rewrite arbitrary application overrides.

## Preserved behavior and limits

Authorization completion keeps cancelled > failed > rejected > approval wait >
authorized priority. Execution completion keeps cancelled > failed > completed.
Validation keeps failure > completed schema handling > authorization. Explicit
approve/reject/dispatch/cancel events keep their legal source phases.
Start execution still precedes mark_running!, preserving dispatch eligibility.

Approval/recovery create fresh FSMSession routing IDs while retaining durable
execution, Tool call and invocation IDs. Parent sinks are session-local. This
change does not alter persistence schema, CAS revisions, approval snapshots,
causal dispatch preparation, stale-result handling, single-writer ownership or
terminal persistence after physical quiescence. Cancellation/timeout do not undo
external effects or forcibly stop workers; exactly-once effects are not promised.

The new tests cover all 48 child guard combinations, legal event sources,
standalone policy loading without Engine/state_machines, worker-result isolation,
owning-environment submission, fresh recovery routing, custom call_async and
physical-completion-aware result transformation. Existing parent transition,
approval, recovery and shutdown suites remain acceptance gates. The AST gate now
also rejects concrete Engine/FSM references and ToolExecutor selection in Agent
tool_execution. Static gates are scoped; they do not prove every dependency valid.

MultiAgent/Workflow FSM and Runtime connections, Workflow durable children,
other concrete composition choices, overall dependency review and additional
live-service/persistence acceptance tests remain. Regenerate the measured graph
from the exact candidate; target diagrams are not measured dependency evidence.
