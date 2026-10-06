# r8 unit 13: C02 Workflow rules and Engine connections

Contract placement follows ownership of meaning and invariants, not reuse.
This unit addresses B04: WorkflowRunner and its registry previously selected
Runtime, built FSMSession instances and constructed Engine event envelopes.
The phase compiler also contained Workflow callback rules alongside the
state_machines translation.

| Owner | Responsibility |
| --- | --- |
| Workflow / C02 | Topology, callback rules, segment admission, identity/owner checks, hydration, snapshots, persistence outcome classification and recovery-required retention |
| Workflow runtime binding | Compile topology into state_machines, build/register sessions, select the owning Runtime and translate classified outcomes into terminal decisions |
| Execution / C13 | Completion handles and receiver lifecycle/routing protocol |
| Engine | Serial dispatch, atomic delivery, generic FSM execution and terminal gate |
| Application | State actions, guards, external event correlation and child operation choices |

WorkflowActionRules owns synchronous entry, transition and exit callback
constraints, optional event arguments and adoption of returned WorkflowContext
values. The compiler installs these rules as machine callbacks. Initial entry
callbacks also pass through the rules before reaching the generic FSM session.
Application callback order remains exit, transition action, entry.

WorkflowExecutionEnvironment is a private C02 connection port. Composition
installs its provider; WorkflowEngineEnvironment implements it. Compiling a
Workflow captures its environment without starting an EventLoop, workers or
execution registration. Starts, durable loads, live signals, terminal saves,
completion and admission release use that same owner. Changing the default
Runtime does not silently move a compiled Workflow or its continuations to a
different owner. Recompile the Workflow after replacing/stopping that Runtime.
Scalar per-call configuration and configured repository resolution retain their
existing behavior. Tracing keeps its independent existing execution composition.

WorkflowExecutionRegistry remains in C02. workflow_instance_id, opaque owner
token and fsm_session_id remain distinct. Routing resolves the current target
under the existing lifecycle lock; ExecutionReceiverBinding constructs the
Engine event within the same atomic delivery operation. No new registry or
public extension API is introduced.

Runner continues to classify terminal persistence results as success, known
failure or outcome unknown. The binding only translates these outcomes into
complete, fail or retire instructions. A successful terminal notification still
requires confirmed persistence. An uncertain outcome still retires the session
while retaining recovery-required admission; it does not announce success or
release another owner's segment. Readback/reconciliation does not retry a save.
Admission is acquired before durable load, and rejected competitors do not load.

## Evidence and remaining scope

Existing tests cover competing admission, immutable terminal snapshots, lost
responses, unknown outcomes, shutdown, wait/resume, live event routing and action
ordering. New tests cover standalone callback rules, resource-free compilation,
owner retention across blocked load/save and default replacement, and rejection
on a stopped owner. Ruby AST and Ruby/RBS graph checks reject C02-to-Engine or
C02-to-binding dependencies while preserving lower-layer restrictions.

The targeted C02 execution connection boundary is addressed. This is not proof
that every logical Contract is complete or that the whole source graph is
acyclic. F01 durable Workflow children still need an explicit specification for
identity, reservation, completion persistence and recovery; application actions
may still launch ordinary asynchronous work. Broader Recovery ownership review
also remains. No durable child protocol or persistence schema is added here.
