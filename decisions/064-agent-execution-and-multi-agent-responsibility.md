# ADR-064: Agent execution and MultiAgent responsibility

Status: accepted for the r8 unit 4 implementation. This amends the Handoff and
coordination ownership portions of ADR-030, ADR-031, ADR-034 and ADR-051.
Acceptance records the authorized design; database validation is reported separately.

Agent owns execution identity, durable admission, semantic observations, finalized
input projection, dispatch prerequisites, terminal changes, retention and
cancellation intent. MultiAgent owns subagent slot reservations/import progress
and Handoff policy, routing, target reservations and history lifecycle.

A versioned, synchronous participant joins Agent's `ExecutionChange` in one outer
Persistence scope. It receives semantic inputs, acquires ordered guards, captures
the pre-state through `prepare_in`, writes its own records and invokes `commit_in`
once. Agent owns validation, record writes and publication after commit. Complete
before/after evidence reconciles ambiguous responses; revision equality alone
does not prove success. No generic raw-record update hook or compatibility alias
is introduced.

Current application wiring is supplied on resume/load and is never serialized.
A saved extension records only binding key, version and content reference.
MultiAgent calls exact execution APIs rather than Agent repositories or private
recovery machinery. Persisted holds prevent purge until the referencing domain
atomically removes its history and releases its own holds.

AgentExecution format 0.2 replaces old coordination metadata. An explicit,
quiescent export/convert/import/verify process preserves IDs, revisions, content
and unresolved outcomes in a separate destination. Runtime does not interpret
old formats. The shared SQL drivers provide runnable migration and rejection of
populated destinations. The complete migration path must be tested on each
production backend before cutover.

Runtime shutdown/AdmissionRegistry and other Engine dependencies remain later r8
work. The measured source graph continues to expose them. See
[implementation responsibilities](../architecture/r8-unit4.md) and
[API/data migration](../migrations/r8-unit4.md).
