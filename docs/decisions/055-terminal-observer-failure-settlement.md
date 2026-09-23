# ADR-055: Settle Terminal Observer Failures

## Status

Accepted on the architecture refactoring branch, 2026-09-23.
Clarifies terminal observer failure ordering in
[026-workflow-runtime-admission-and-durable-terminal-barrier](026-workflow-runtime-admission-and-durable-terminal-barrier.md).
It does not move Workflow terminal policy out of FSMSession; that remains W2b.

## Problem

FSMSession marked itself done before delivering a pending stable-state observer
notification. If that observer raised at a wait state or a declared terminal
state, the existing error handler saw done and returned without an error event.
The synchronous stream caller remained blocked and Workflow admission stayed
owned. Durable executions could already have saved their terminal snapshot.

The existing observer-exception test covered an automatic transition's ordinary
stable notification, before terminalization. It did not cover the deferred
terminal notification. Six real-runtime observations on both pre-Refactor-31 and
applied Refactor-31 source reproduce four affected cases and two unaffected
automatic-transition controls. This is not a regression introduced by Refactor 31.

## Decision

Keep the existing terminal lifecycle selection, invoke the pending stable
observer, and set done only after the observer returns successfully. If it
raises, the existing start/handle/request error boundary emits the ordinary
error event with the original exception. EventLoop retires the session and the
existing Runner completion path releases admission before failing the caller.

Preserve successful notification-before-terminal-event ordering. All transitions
remain on EventLoop. Do not introduce a new class, callback retry, extra save,
Task settlement path, or direct admission mutation from the observer.

## Durable meaning and limits

A durable terminal observer runs only after the session accepts a known-success
save result. Observer failure therefore means notification failed; it does not
mean the save failed, and must not erase, roll back, or repeat the saved record.
The caller receives the original observer exception. Applications must not
assume that every raised stream exception proves non-commit, nor replay external
effects automatically. This adds no exactly-once or crash-atomic notification
guarantee; existing F1/F4/X0 limits remain.

Known save failure and unresolved save uncertainty are unchanged. In particular,
the outcome-unknown path still retires the session without falsely settling the
Workflow Task or releasing its recovery-required admission.

## Verification

Add public stream regressions for wait/declared-terminal boundaries, each with
and without persistence. Require the same exception object, one notification
on EventLoop, caller completion, session retirement and admission release.
For durable cases, also require the existing snapshot and revision 1 to remain.
Keep test cleanup bounded so these tests can demonstrate failure on old source.

Run the shared FSMSession/Agent/Tool tests, Workflow admission and F1 tests, full
and integration suites, API/RBS/style, examples and real SQLite. Keep W2b policy
extraction in a later package after application verification of this fix.
