# ADR-043: Storage-Owned Execution Constraint Notifications

The raw fixed-repository/error portions are amended by [ADR-058](058-neutral-storage-primitives.md). Domain ownership and applicable transaction/uncertainty decisions remain in force.


**Status**: Accepted
**Date**: 2026-09-21
**Refines**: [033-domain-persistence-ownership](033-domain-persistence-ownership.md) and the Beta Backend error contract in [persistence-backends](../persistence-backends.md)

## Problem

InMemory and the SQLite/PostgreSQL reference backends raised `AgentBusyError`
for stored nonterminal-execution constraints. A storage implementation therefore
selected a feature lifecycle exception, even though domain repositories already
owned record conversion and public operation semantics.

## Decision

`Storage::ActiveExecutionConflictError < Storage::ConflictError` identifies only
a stored nonterminal execution preventing another admission or an idle-only
operation for the same owner. It contains no Agent/Team class, domain object,
callback, or new persisted field. Generic duplicate IDs, stale revisions and
other precondition failures remain ordinary `Storage::ConflictError` values;
connection errors and uncertain outcomes retain their existing error types.

Raw execution repositories use this subtype from `create_active`, `assert_idle!`,
and any existing `save` branch that detects the same active-owner constraint.
Agent and MultiAgent execution repository facades translate only this subtype
to the existing public `AgentBusyError`, preserving its message and Ruby cause.
They do not catch every `ConflictError` or reinterpret database exceptions.
The existing Team public error remains unchanged; choosing a different Team
lifecycle exception would be a separate API decision.

Constraint detection and the write remain inside the same backend consistency
boundary. No preflight lookup is moved above the backend. Domain translation
occurs inside the existing transaction block so the mapped exception still
causes rollback before commit. SQL statements, lock order, connection binding,
indexes, persisted records and transaction boundaries are unchanged.

## Compatibility and migration

This intentionally changes the Beta raw Backend error contract. Callers of
`backend.executions` and `backend.team_executions` must catch the new storage
subtype instead of `AgentBusyError`. Callers of the domain-facing Persistence,
Agent and Team APIs continue receiving `AgentBusyError` for that condition.

The core, InMemory and both reference SQL backends are migrated together. Apply
the core before the new SQL sources; the new backend sources require the new
storage constant. An old backend that still raises `AgentBusyError` passes
through an updated domain facade unchanged, but no longer conforms to the new
raw SPI. There is no fallback alias in Storage or Engine.

The shared backend suite now checks raw notifications separately from domain
exceptions, including duplicate-ID and stale-revision distinction and rollback.
The storage isolation guard removes its former Agent lifecycle file exemption.

## Guarantees and limits

| Subject/property | Provider | Failure/boundary | Result |
|---|---|---|---|
| One nonterminal execution per stored owner | Existing atomic admission, backend lock/transaction/DB constraint | F2; no X0 | CONDITIONAL on the backend satisfying the existing atomic_admission contract; no new cross-process owner lease |
| Uncommitted writes roll back when a mapped constraint escapes | Existing storage transaction with domain conversion inside its block | F0/F2; no X0 | YES for an ordinary known pre-commit constraint failure; not a claim about uncertain commits |
| Caller-facing busy errors retain their meaning | Feature repository translation of the dedicated subtype | F0/F2; no X0 | YES for the documented domain repository paths; unrelated conflicts are not converted |

This change adds no F1 outcome reconciliation, F4 rehydration, external-effect
rollback or exactly-once guarantee. The eight repository names and Agent
watermark that ADR-033 leaves in Storage remain an explicit intermediate state.
Removing the exception dependency does not make the entire SPI domain-neutral.

## Rejected alternatives

- Move `AgentBusyError` into common definitions or alias it from Storage.
- Translate every `ConflictError` into a busy error.
- Check active state in the domain facade before performing a separate write.
- Migrate only InMemory and silently leave the SQL raw contract inconsistent.
