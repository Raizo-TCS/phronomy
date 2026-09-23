# ADR-056: Workflow-Owned Terminal Policy

## Status

Accepted on the architecture refactoring branch, 2026-09-23.
Amends the implementation ownership in
[ADR-026](026-workflow-runtime-admission-and-durable-terminal-barrier.md).
Preserves the ordering and failure semantics clarified by
[ADR-055](055-terminal-observer-failure-settlement.md).

## Context

FSMSession is used by WorkflowRunner, AgentInvocationSessionBuilder and
ToolInvocationSessionBuilder. It belongs to Engine, but it directly recognized
Workflow persistence events and interpreted success, known failure and unknown
save outcomes. Moving the entire session would couple Agent and Tool to Workflow.
Runner already owns the one terminal save and F1 reconciliation (ADR-054), and
WorkflowExecutionRegistry already owns admission and owner tokens (ADR-042).

## Decision

WorkflowRunner injects a WorkflowTerminalPolicy only for durable execution.
Ephemeral Workflow, Agent and Tool sessions keep their immediate terminal path.
The policy holds the persistence callback, not live session state or admission.

The private session protocol is:

- `start(terminal_type:, context:, event_sink:)` begins the barrier on EventLoop.
  Its return value does not authorize completion. Results use the bound sink.
- `handles?(event)` recognizes a policy event, including an early event that
  must be discarded by the session before any terminal request.
- `decision_for(event)` interprets an accepted event and returns the immutable
  `FSMProtocol::TerminalDecision(action:, error:)` value.

WorkflowTerminalPolicy maps success to `complete`, known failure to `fail` with
its original error or the existing fallback error, and outcome unknown to
`retire` with its diagnostic error. Invalid Workflow outcomes remain errors.
FSMSession knows these generic actions, not the Workflow event or outcome values.
An unsupported action fails through the existing session error path.

FSMSession alone owns the pending terminal type, stable-notification flag and
acceptance state. It enters `awaiting_terminal` before starting the policy,
ignores ordinary events during that wait, ignores early policy events, and
accepts at most one terminal decision. The policy must not maintain a second
pending lifecycle or mutate the session from a worker.

`complete` delivers any deferred stable notification before marking done and
posting the terminal event. `fail` uses the existing failure path. `retire`
marks the session retired and uses EventLoop's existing recovery-required
management route without settling a result. Runner persistence/F1 code,
Registry ownership and EventLoop retirement/shutdown code remain unchanged.

## Uncertainty and shutdown

Retirement for an unknown save result removes the concrete routing session and
retains recovery-required admission. It does not complete or fail the caller.
The old sink cannot target a subsequent incarnation. Normal Runtime shutdown
clears Registry ownership and terminates the dispatcher, but does not synthesize
a Workflow result: the unresolved caller remains pending. Unexpected dispatcher
failure has its separate existing waiter cleanup. These are preserved behaviors,
not a new guarantee of automatic recovery or a stronger F1/F4/X0 contract.

## Compatibility and non-goals

`terminal_barrier:` is replaced by private `terminal_policy:` with no alias.
The internal lifecycle names change to `awaiting_terminal` and `retired`.
Neither constructor injection nor these states are a new public plugin API.
Without an injected policy, Engine no longer reserves a Workflow-only event
name. Workflow's producer emits that event only for its durable execution path.
Session identity, EventSink correlation, public Workflow/Agent/Tool APIs,
Workflow result types, durable records and Storage SPI are unchanged.

Do not move snapshot persistence into the policy, settle caller Tasks there,
rename outcome strings while leaving interpretation in Engine, introduce a
subclass/prepend override, or duplicate admission. A small new policy and value
type clarify ownership; reducing the total line count is not the objective.

## Verification

The generic session contract uses a non-Workflow event and policy, exercising
early/ordinary/duplicate events, completion, failure, retirement, submission
error, malformed decisions and the immediate default path. Workflow tests cover
invalid outcomes and the existing missing-error fallback through Runner wiring.
Real Runtime tests cover F1 pre-state, conflicting/unreadable readback, retained
admission and normal shutdown, stale sinks across incarnations, and submission
rejection. Existing delayed-save, halted-stream, observer-failure, Agent/Tool and
F1 tests remain acceptance gates; rejected result delivery must not retry save.
