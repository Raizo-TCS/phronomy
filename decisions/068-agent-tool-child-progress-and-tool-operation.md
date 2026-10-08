# ADR-068: Agent owns Tool child progress; Tool owns its operation protocol

Status: accepted for the r8 unit 8 candidate. Extends
[067-agent-progress-and-engine-connection](067-agent-progress-and-engine-connection.md)
to Tool children and refines the operation boundary in
[066-llm-and-tool-operation-contracts](066-llm-and-tool-operation-contracts.md).

## Decision

Keep Tool child transitions, approval waiting, dispatch eligibility, outcome
application and parent notification in C04. Use one ordered transition definition
for both concrete FSM construction and source admission. Move FSMSession and
state_machines construction into Agent runtime_binding. Pass the original Agent
execution environment explicitly to child authorization and execution.

C06 owns standard/custom Tool operation dispatch, execution-mode validity,
completion protocol and result adaptation. It accepts the C13 submitter protocol
for standard offloaded work. Agent uses the public operation rather than
inspecting the implementation owner and calling the private default executor.
Custom Tool#call_async overrides keep their public signature and own mechanism.

## Reason

The previous builder mixed Agent rules with concrete connections and duplicated
transition definitions. Agent also selected Tool implementation paths in both
invocation and result binding. Moving whole classes to an adapter or assigning
all Tool-related progress to C06 would preserve or misplace those responsibilities.

## Consequences

The boundary now supports independent Agent policy tests and Engine adaptation
tests. No concrete Runtime or Agent type enters C06. Existing durable identity,
approval/recovery, causal revision and physical-quiescence guarantees remain.
No new exactly-once or in-flight version compatibility is claimed. See
[the unit 8 scope](../architecture/r8-unit8.md) and
[migration instructions](../migrations/r8-unit8.md).
