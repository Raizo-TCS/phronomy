# r8 unit 7: C04 Agent progress and execution connection

Contract placement follows ownership of meaning, invariants, operations and
failures. It is not determined by reuse. This unit improves C04; it does not mark
all of C04, C06 or the overall target complete.

| Owner | Responsibility after this change |
| --- | --- |
| Agent InvocationTransitions | Phase vocabulary, ordered automatic/external transitions, guard evaluation, iteration bound |
| Agent InvocationActions | Prepared input, LLM dispatch, Tool batch orchestration and result/event interpretation |
| Agent ExecutionCoordinator / RecoveryCoordinator | Admission, durable preparation, approval, terminal outcome, recovery and causal revision checks |
| Agent ExecutionEnvironment | Private process-local connection required by the Agent framework; session construction/registration, serial owner and operation submission |
| Agent EngineEnvironment / EngineSessionBuilder / PhaseMachineBuilder | Runtime registration, EventLoop channel, FSMSession construction and state_machines adaptation |
| ExecutionReceiver | Serial-owner admission, delivery and lifecycle framework for feature-owned live state |
| Engine ExecutionReceiverBinding | Concrete EventLoop registration, locking, queued delivery and routing |

Previously AgentInvocationSessionBuilder combined Agent entry operations with
FSMSession creation. PhaseMachineBuilder held automatic progress rules, while
InvocationTransitions held only external transitions. Execution/recovery also
selected Runtime.instance repeatedly. The split now leaves both transition sets
and their priority with Agent. The Engine builder only installs those definitions
and synchronous entry callbacks into state_machines. InvocationActions retains
Agent semantics instead of moving the old class wholesale into an adapter.

An Agent captures the environment of its ownership registry at construction.
Execution and recovery reuse it; changing the composition provider does not move
a live Agent to another Runtime. Cancellation records its durable request before
posting a notification through that same environment, including after a provider
change. Detached Agent cancellation is rejected by the existing live-owner check.
The default provider is installed lazily by runtime_composition/agent_defaults.rb.
This is an internal composition port, not a new supported application plugin API.

ExecutionRegistry remains Agent-owned. Its generic serial receiver framework
moves from Engine to Execution and receives a channel. The actual EventLoop
transport stays in Engine. WorkflowExecutionRegistry uses that same channel to
preserve its existing receiver lifecycle; Workflow policy is not migrated here.
This placement follows ownership of execution admission/lifecycle, not merely
that Agent and Workflow share a base class.

Provider Call identity is passed explicitly to AgentInvocation from the already
prepared durable execution. AgentInvocation no longer queries global Runtime to
find it. FSMSession IDs remain ephemeral routing incarnation IDs. Approval and
recovery create a fresh session while preserving durable execution/LLM/Tool IDs.
No storage schema, CAS revision, parent admission, atomicity or F0/F1/F4 policy
changes. External effects are not exactly-once. Cancel/timeout do not forcibly
stop workers or undo effects; terminal persistence still waits for physical
quiescence. Stale session/revision results remain rejected on the serial owner.

## Evidence and limits

The tests execute the transition policy in a standalone Ruby process without
Engine or state_machines, enumerate all 32 Tool outcome priority combinations,
compare the Engine adapter's behavior, and check environment retention and
cancellation routing. Existing recovery, approval, callback failure, single-writer,
stale-result and shutdown tests remain part of full/integration validation.
An AST gate rejects concrete Engine constants and state_machines loading in Agent
execution, recovery, lifecycle and ExecutionEnvironment. This is a scoped gate,
not proof that every dependency in the system is correct.

The measured graph adds M88/G62 for agent/runtime_binding; retired IDs are not
reused. Ruby and RBS references remain in the evidence, including cycles caused
by other uncompleted boundaries. Regenerate the measured diagram from the exact
candidate; do not treat it as the acyclic target design.

Still pending: Agent's Tool child FSM/session builder and its Runtime selection;
MultiAgent and Workflow FSM/Runtime connections; Workflow durable children and
cross-record outcome evidence; broader dependency-triangle review. The C06 Tool
operation/schema contract established in unit 6 remains intact, but its Agent-side
execution connection is not declared complete by this unit. LLM AsyncClient's
execution backend selection also remains the existing C09/C13 composition.
