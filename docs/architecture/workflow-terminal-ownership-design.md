# Workflow terminal ownership: design validation

Baseline: core `42f61514929645662e16b571afff9f4060d867d1` and examples
`2f8b467f1268dd21de4c02b1c90c8bdd211d1feb`, 2026-09-23.
W2a (Refactor 32) fixes the proven observer defect. W2b below is a proposed
ownership boundary, not an implemented or Accepted new session protocol.

## Role and actual consumers

FSMSession drives one live state machine on EventLoop. AgentInvocationSessionBuilder,
ToolInvocationSessionBuilder and WorkflowRunner all construct it. Moving the
whole class into Workflow would make two other domains depend on Workflow.
EventLoop owns registration, routing and retirement; it does not perform the
Workflow save. WorkflowExecutionRegistry owns admission and owner tokens.

The remaining leak is narrower: FSMSession recognizes a Workflow persistence
result event and interprets its success/known-failure/outcome-unknown values.
Runner already owns snapshot capture, immutable worker input, one save, and F1
readback. Do not move that persistence work or recreate admission in a controller.

## Current successful durable terminal sequence

1. Session reaches a logical wait/completion boundary and updates context metadata.
2. Runner marks admission persisting_terminal and captures the immutable command.
3. Offload saves once and reconciles an uncertain result when possible.
4. The owning session receives the result through its bound EventSink.
5. On known success, any deferred stable observer is called, then the terminal
   management event is published.
6. EventLoop retires the session and settles its source Task; Runner releases
   admission before settling the caller Task.

Unresolved uncertainty follows a different path: session retirement notifies
WorkflowExecutionRegistry, admission becomes recovery_required and caller/source
completion is not falsely settled. EventLoop retains the waiter for existing
shutdown cleanup. This path must not be collapsed into ordinary failure.

## Validation finding: terminal observer exception

`complete_terminal!` set done before calling the deferred stable observer.
An exception then reached `finish_with_error`, which returned because done was
already true. No terminal management event was posted, leaving both stream and
admission active. The automatic-transition observer test did not exercise this
path. Both wait and declared-leaf boundaries fail, with and without persistence.
The same behavior exists before W1; FSMSession was unchanged by Refactor 31.

W2a moves the done assignment after notification. It retains the selected
terminal lifecycle state, so an observer cannot start another terminal request;
if notification raises, the existing error path can settle the failure. Confirmed
durable state remains saved. The caller exception does not establish non-commit.
See [ADR-055](../decisions/055-terminal-observer-failure-settlement.md).

## Ownership alternatives

| Alternative | Assessment |
|---|---|
| Move all FSMSession into Workflow | Reject: Agent and Tool are real consumers of the generic engine. |
| Rename Workflow event/outcome values in Engine | Reject: hides rather than moves domain interpretation. |
| Save after session retirement or on a worker completion callback | Reject: violates the durable barrier and EventLoop authority. |
| Workflow-specific subclass or prepend | Avoid: adds another override path and protected coupling immediately after removing one. |
| Inject a small Workflow-owned policy through a private session boundary | Preferred direction; validate the boundary before adopting concrete names or signatures. |

## Proposed boundary for W2b

| Owner | Responsibility after extraction |
|---|---|
| FSMSession | Identity/sink, state-machine transitions, live context, generic pending-terminal gate, exactly one terminal notification/event path. |
| Workflow terminal policy | Recognize the Workflow persistence event; map its semantic result to permission to complete, ordinary failure, or retirement with the caller unresolved. |
| WorkflowRunner | Construct the policy; preserve terminal snapshot submission, one save, F1 readback and final caller completion. |
| WorkflowExecutionRegistry | Admission, owner-token checks, routing bind/unbind, recovery-required retention. |
| EventLoop | Session routing, management events, source completion and existing shutdown behavior. |

A candidate private protocol needs four operations: start the domain barrier,
recognize a domain event, interpret its result, and return one generic terminal
decision. An immutable decision may distinguish complete/fail/retire without
settling; the exact type, method names and whether the existing protocol values
suffice are implementation design choices still to validate.

Keep one owner for pending terminal type, notification flags and event acceptance.
Do not duplicate the full lifecycle in Session and policy. The Engine must not
switch on `workflow_terminal_persistence_result`, `known_failure` or
`outcome_unknown`. Its existing generic retirement infrastructure may remain;
removing an event name is not a reason to alter waiter retention or shutdown.
A new policy must not mutate the live session from Offload or settle caller Tasks.
Agent/Tool retain their immediate default terminal path without a fake barrier.

## Required acceptance matrix

| Scenario | Required observation |
|---|---|
| Ephemeral normal completion/halt | No save; existing notification and result order. |
| Delayed durable save | No terminal notification or Task result before session acceptance. |
| Portable known failure | Original error, admission release; no terminal success or automatic retry. |
| F1 post / pre / conflict / unreadable | Preserve reconciliation and known-vs-unknown semantics. |
| Unknown result | Retirement with recovery-required admission and unresolved caller; same shutdown cleanup. |
| Early, duplicate, late events | At most one accepted terminal decision; no stale sink rebinding or effect on a new incarnation. |
| Ordinary event during save | No continuation authority while a terminal result is pending. |
| Observer exception at wait/leaf | W2a behavior: original exception, one notification, session retired, admission released, saved record retained. |
| Submission error or rejected delivery | Preserve existing errors/logging and distinguish runtime shutdown from an accepted result. |
| Agent/Tool sessions | Identity, callback correlation, immediate terminal behavior and builder contracts unchanged. |

The existing source-layout/identity tests explicitly require `terminal_barrier`
and Workflow-specific text in FSMSession. Update those assertions only when the
new owner/protocol is implemented and behavior tests cover the replacement.
They are not evidence that the old ownership must be preserved indefinitely.

## Staging and completion

1. Apply and verify W2a/Refactor 32 independently; its production change only
   reorders one assignment and adds an explanation.
2. Implement and exercise the proposed W2b boundary in an isolated candidate.
   Confirm its exact protocol, load behavior, private compatibility and all
   acceptance cases; amend ADR-026 ownership with a new decision.
3. Deliver W2b complete files only after that validation. Update the source-based
   diagram after its application is verified.

The design review establishes actual consumers, the owner map and the prerequisite
fix. It does not claim W2b code or its future acceptance matrix is already tested.
Storage S1-S3 remains after Workflow terminal ownership.
