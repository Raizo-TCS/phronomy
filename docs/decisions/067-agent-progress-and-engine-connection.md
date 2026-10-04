# ADR-067: Agent progress owns policy; composition supplies its execution connection

Status: accepted for r8 unit 7 candidate. Supersedes the construction ownership
portion of the Agent transition design; durable guarantees are unchanged.

## Decision

Keep progress rules, entry operations, admission, approval and recovery decisions
inside Agent. Introduce the private ExecutionEnvironment connection and an Engine
implementation. Bind a live Agent to the environment of its ownership registry.
Move concrete session/phase-machine construction to agent/runtime_binding.
Keep state_machines out of InvocationTransitions. Extract the serial receiver
lifecycle framework to Execution with an Engine-owned channel implementation.

## Why

The old session builder mixed domain operations with concrete FSM construction.
Repeated Runtime.instance lookups made execution connection selection implicit.
Moving all code into a binding would relocate the same semantic mixture.
A contract owns executable rules, not just signatures or forwarding methods.

## Consequences

The application invoke/stream/approval/recovery API is unchanged. Internal
AgentInvocationSessionBuilder is removed with no alias. Private receiver
constructors now accept a channel. Internal embedders must adopt the composition
port and respect serial mutation, bounded submission, shutdown and session
incarnation rules. Tool child and other domain FSM decomposition remain separate
work. See ../architecture/r8-unit7.md for scope and verification.
