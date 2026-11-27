# Completion facts: current implementation and extraction history

Agent outcome, approval and dispatch recovery and Workflow terminal recovery use
shared attempt management and completion evidence. Domain authorization,
persistence interpretation, application, continuation and release remain with
their original owners.

For example, a save worker can finish after its first observer is cancelled.
The common evidence record preserves the worker result, while Agent and Workflow
still make different decisions after a confirmed noncommit.

As of 2026-11-28, the current implementation is documented in
[shared retained-attempt management](retained-attempts.md). C13
`RetainedAttempts` manages the initial attempt, recovery lane and observers;
C13 `AttemptCompletion` stores completion evidence. The former
`Agent::PhysicalAttempt` class and source path are removed without an alias.
Workflow participates in this implementation. The historical figures below
apply only to the earlier Agent-only extraction.

## Original Agent-only extraction

The first extraction shared completion bookkeeping between the Agent terminal
and approval owners while leaving their identity, admission and observation
management separate. It preceded the broader four-owner implementation.

For example, terminal recovery could apply a confirmed result or retain an
explicit save retry, while approval recovery could restore its original wait
or resume a retained continuation. Their completion mailbox was reusable even
though those domain decisions differed.

| Responsibility in the original extraction | Historical location |
| --- | --- |
| Task handle, logical/physical facts, worker result and registration error | `Agent::PhysicalAttempt` |
| Task callbacks, snapshot fallback and worker-result precedence | `Agent::PhysicalAttempt` |
| Identity, started/refused/unknown evidence and observer membership | Individual Agent recovery owner |
| Pre/post interpretation, retry authorization, live application and release | Individual Agent recovery owner |

Each original owner kept a slot containing its own facts and one completion
record. Workflow was excluded from that first extraction pending an independent
comparison. The later shared manager supersedes that placement and the mutable
slot interface; it does not supersede the distinct domain policies.

## Atomicity and cleanup preserved by the first extraction

The extracted completion record used its owner's existing mutex to combine
completion evidence with domain decisions. Task methods and owner notifications
ran outside that mutex because callback registration could invoke a callback
immediately.

For example, an inline physical callback could publish its fact and notify the
owner before registration returned. A later logical snapshot could not replace
an explicitly recorded worker result, including a successful `nil` value.

The original protocol retained physical evidence when a poll was less
informative, kept a handle after partial notification registration, and isolated
old completion records from replacement attempts. It did not infer physical
completion from logical completion for a task offering a separate physical
protocol. Owner release or resolution controlled reference cleanup.

The first extraction also cleared a private registration-error reference that
terminal recovery had previously retained after release. That was a bounded
reference cleanup, not a new lifecycle state or a guarantee against arbitrary
nonstandard delayed callbacks. Current cleanup commands preserve the distinction
between releasing only the task and releasing all completion references.

## Original cost and acceptance scope

The first extraction removed a second implementation of completion observation
and refresh. Its cost included another private class, a record per attempt,
temporary snapshots and a shared-lock precondition. Its size measurements did not
establish a large reduction across the framework.

For example, a correction to worker-result precedence then reached both Agent
owners through one implementation, while approval restoration and terminal save
retry still required their own Runtime acceptance tests.

Against `f08d26c59b77b0157e0fa7e267fb299516342c8f`, the two owners shrank from
1,105 to 1,031 physical lines. The new record added 86 lines, so combined source
grew by 12 lines. Excluding blank and comment-only lines, the combined count
fell from 982 to 973, a reduction of nine lines. These are historical figures,
not measurements of the current shared manager or a performance claim.

The original record tests exercised inline callbacks, logical/physical
separation, worker-result precedence, partial registration failure, snapshot
races and old-attempt isolation. The current protocol additionally removes
preparation-time task reattachment and captures the completion record and task
in one refresh read. Its current responsibilities, lock rationale, model mapping
and acceptance obligations are in [the current design](retained-attempts.md).
