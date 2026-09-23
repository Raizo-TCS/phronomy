# ADR-054: One Workflow Terminal Save Implementation

## Status and scope

Accepted on the architecture refactoring branch, 2026-09-22.
Amends only the Workflow recovery prepend requirement in
[038-responsibility-based-source-layout](038-responsibility-based-source-layout.md).
The durable barrier in
[026-workflow-runtime-admission-and-durable-terminal-barrier](026-workflow-runtime-admission-and-durable-terminal-barrier.md)
and the receiver ownership in
[042-feature-owned-execution-state](042-feature-owned-execution-state.md)
remain unchanged.

## Problem

WorkflowRunner defines terminal save submission, but WorkflowRecovery defines
the same method and is prepended during application loading. It never calls
`super`. The active implementation reconciles uncertain save outcomes against
durable pre/post state; the shadowed implementation does not. Reading or editing
the Runner alone can therefore target code that is not actually used.

## Decision

Move the currently active submission and F1 reconciliation into WorkflowRunner.
Delete the shadowed implementation, the private WorkflowRecovery module and its
explicit installation. Do not introduce a new class or compatibility alias for
the removed private override.

Express terminal save submission as admission marking, immutable command
construction, Offload submission and session-local result delivery. Named private
methods own saving/reconciliation and delivery separately. The existing Command
and Result Data classes retain their identity and members.

The worker saves once. Portable ConflictError, NotFoundError, SerializationError
and UnsupportedBackendError remain known failures without readback. Other save
errors use the existing authoritative snapshot comparison: exact post-state is
success, pre-state preserves the original failure, and conflict or failed
readback remains outcome-unknown. No automatic save retry is introduced.

The existing session sink receives `workflow_terminal_persistence_result`.
Offload completion errors still become outcome-unknown, and rejected sink
delivery retains its existing warning. Runner still marks admission and captures
the snapshot on EventLoop; workers only use that captured command for persistence.

## Compatibility and guarantees

This is an internal ownership/readability change. Public Workflow/Persistence
APIs, Backend SPI, snapshots, revisions, error messages and the session event
protocol are unchanged. Removing the prepend can make WorkflowRunner load lazily
under ordinary `require "phronomy"`; first access and eager loading must retain
the same recovery behavior without starting Runtime.

F1 save certainty remains CONDITIONAL on authoritative readback matching the
existing expected pre-state or intended post-state rules. It is not established
merely by receiving an exception. F0 portable failures follow the existing known
failure path. Runtime release, success notification and Task settlement still
wait for EventLoop-owned session acceptance; uncertain outcomes keep the existing
recovery-required behavior. F4 readability depends on the backend retaining
confirmed data. X0 external effects are outside this save, and this change adds
no execution replay, distributed ownership or exactly-once guarantee.

FSMSession still owns interpretation of the Workflow terminal persistence
event. Moving that policy out of Engine is a separate next step; this decision
does not claim that the entire Workflow terminal ownership issue is resolved.
Storage's fixed repository slots and Agent watermark also remain separate work.

## Verification

Characterize the effective submission path before and after the change, including
immutable snapshots, known errors, F1 post/pre/conflicting/unreadable outcomes,
single-save behavior and failed Offload completion delivery. Preserve existing
real-runtime tests for delayed save, stream barriers, admission release and
uncertain outcomes. Verify ordinary/eager loading without the override, full and
integration suites, API/RBS/annotations/style, offline examples and built gem
contents. Keep results from tests actually run distinct from unavailable live
Provider or database-server evidence.
