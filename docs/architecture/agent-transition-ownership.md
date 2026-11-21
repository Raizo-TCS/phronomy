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

## Initial execution registration

An Agent's coordinator owns the registration and terminal delivery of that
Agent's execution. A rejected registration does not acquire an existing
execution merely because both requests use the same execution ID. Agent
admission, durable outcome and completion delivery remain separate boundaries.

For example, if a second Agent in another Store reserves an ID already active
in the Runtime, its failed start must not release the first Agent, settle the
first Agent's waiters or alter its physical-work accounting. The second Agent
records its own failure when persistence confirms it, and receives only its own
operation result. The first Agent can continue and finish normally.

If registration installed this Agent's live state before session startup failed,
the coordinator uses its normal owned terminal path, including physical-work
quiescence and waiter delivery. If no state was installed, the terminal operation
uses only its own request task and admission; it does not read or drain another
owner's live state or waiter collection by ID.

An unconfirmed durable outcome stays recovery-required. A failure to commit or
submit a terminal write for an unregistered start settles that start's own
operation with the error; it does not fabricate a confirmed failed execution.
Registered executions retain their existing recovery behavior.
