# Agent transition ownership (r8 unit 7)

InvocationTransitions owns both automatic and external transitions, including
ordered guard evaluation. InvocationActions owns Agent entry operations.
EngineSessionBuilder configures FSMSession using those definitions;
PhaseMachineBuilder adapts them to state_machines without defining progress rules.
ExecutionCoordinator and RecoveryCoordinator retain durable decisions and use
the Agent-owned ExecutionEnvironment port for execution connection.

See [r8 unit 7](r8-unit7.md) and [ADR-067](../decisions/067-agent-progress-and-engine-connection.md).
Existing event source validation, callback failure priority, short-circuiting,
Tool outcome priority, suspended/wait/terminal boundaries and session incarnation
rules are preserved. Agent's Tool child FSM is still a separate remaining task.
