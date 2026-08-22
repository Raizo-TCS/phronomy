# Architecture Decision Records

This directory contains Phronomy Architecture Decision Records (ADRs).

The repository-wide architecture authority model is defined by
[`017-design-authority-and-adr-governance`](017-design-authority-and-adr-governance.md).
This index is the canonical navigation surface for ADR identity, status, and
supersession relationships.

## Canonical ADR identity

The **canonical decision key** is the ADR filename basename, for example:

```text
012-canonical-execution-log-and-context-policy
```

The three-digit numeric prefix is an ordering/display number. It is not, by
itself, a globally unique historical identifier because this repository
already contains two legacy ADRs numbered `011`.

Therefore:

- new or modified normative material SHOULD link to the ADR file or use its
  full canonical decision key;
- the bare label `ADR-011` is ambiguous and MUST NOT be used to identify one
  of the two legacy `011` decisions;
- existing historical text is not rewritten merely to normalize old
  references.

## Status and authority

ADR status has architecture meaning:

- **Accepted** — normative architecture intent unless explicitly superseded.
- **Amended** — normative architecture intent including its recorded
  amendments.
- **Superseded** — retained as decision history; non-normative for the
  superseded scope.
- **Proposed** — not normative until accepted.

An Accepted ADR can temporarily disagree with implementation reality. That is
an **architecture inconsistency**, not permission to silently treat whichever
artifact is newer as authoritative. The inconsistency must be tracked and
resolved explicitly.

## ADR index

| Canonical decision key | Status | Normative now? | Supersession / note |
|---|---|---:|---|
| [`001-rubyllm-as-provider-layer`](001-rubyllm-as-provider-layer.md) | Accepted | Yes | Current intent; implementation-boundary reconciliation may be tracked separately. |
| [`002-workflow-context-immutability`](002-workflow-context-immutability.md) | Accepted | Yes | Current immutability intent; ownership details may be refined separately. |
| [`003-event-loop-singleton`](003-event-loop-singleton.md) | Accepted | Yes | Current until explicitly superseded/refined. |
| [`004-invoke-timeout-is-not-cancellation`](004-invoke-timeout-is-not-cancellation.md) | Superseded | No | Superseded by [`011-delegate-transport-policy-to-adapters`](011-delegate-transport-policy-to-adapters.md). |
| [`005-static-knowledge-class-level-cache`](005-static-knowledge-class-level-cache.md) | Superseded | No | Superseded by [`013-journal-backed-knowledge-as-context-candidates`](013-journal-backed-knowledge-as-context-candidates.md). |
| [`006-no-built-in-guardrails`](006-no-built-in-guardrails.md) | Amended | Yes | Current policy intent; legacy Guardrail terminology is subject to separate reconciliation. |
| [`007-mcp-is-beta-stability`](007-mcp-is-beta-stability.md) | Accepted | Yes | Current. |
| [`008-orchestrator-uses-os-threads`](008-orchestrator-uses-os-threads.md) | Superseded | No | Superseded by [`010-cooperative-first-concurrency`](010-cooperative-first-concurrency.md). |
| [`009-state-store-abstraction`](009-state-store-abstraction.md) | Superseded | No | Superseded by [`014-unified-persistence-durable-state`](014-unified-persistence-durable-state.md). |
| [`010-cooperative-first-concurrency`](010-cooperative-first-concurrency.md) | Accepted | Yes | Current until explicitly refined/superseded. |
| [`011-build-context-as-single-llm-input-authority`](011-build-context-as-single-llm-input-authority.md) | Superseded | No | Superseded by [`012-canonical-execution-log-and-context-policy`](012-canonical-execution-log-and-context-policy.md). |
| [`011-delegate-transport-policy-to-adapters`](011-delegate-transport-policy-to-adapters.md) | Accepted | Yes | Legacy duplicate numeric prefix; use the full canonical key. |
| [`012-canonical-execution-log-and-context-policy`](012-canonical-execution-log-and-context-policy.md) | Accepted | Yes | Current Journal / Manifest / Context authority. |
| [`013-journal-backed-knowledge-as-context-candidates`](013-journal-backed-knowledge-as-context-candidates.md) | Accepted | Yes | Current persistent Knowledge authority. |
| [`014-unified-persistence-durable-state`](014-unified-persistence-durable-state.md) | Accepted | Yes | Current intent until coherent successor decisions are accepted; known implementation reconciliation is handled explicitly rather than by silent rewrite. |
| [`015-tool-public-facade-and-rbs-boundary`](015-tool-public-facade-and-rbs-boundary.md) | Accepted | Yes | Current Tool façade / extension-SPI / RBS boundary. |
| [`016-semantic-multi-agent-handoff`](016-semantic-multi-agent-handoff.md) | Accepted | Yes | Current Handoff intent; implementation reconciliation may remain open without changing this status silently. |
| [`017-design-authority-and-adr-governance`](017-design-authority-and-adr-governance.md) | Accepted | Yes | Repository-wide architecture authority and ADR governance. |

## Legacy duplicate `011`

The repository intentionally preserves both legacy files:

```text
011-build-context-as-single-llm-input-authority
011-delegate-transport-policy-to-adapters
```

They are different decisions. The first is superseded by ADR-012; the second
remains Accepted.

They MUST NOT be silently renumbered. Their filenames are stable historical
decision keys. New decisions may not introduce another duplicate numeric
prefix.

## Allocating a new ADR identifier

For a new ADR:

1. inspect all `NNN-*.md` files in this directory;
2. allocate `max(existing numeric prefix) + 1`;
3. format the number with three decimal digits;
4. never fill an old gap and never reuse an existing prefix;
5. if two unmerged changes select the same number, the change merged later
   rebases and renumbers **only its new, not-yet-historical ADR**;
6. add the ADR to this index in the same change.

Existing ADRs are not renumbered merely because a numbering defect is later
discovered. `016-semantic-multi-agent-handoff` is therefore preserved as-is.
Under this rule the Design Authority decision is ADR-017.

## Superseding or amending a decision

Do not rewrite historical rationale into a fictional current history.

When superseding an ADR:

- add a new decision describing the new architecture;
- update the old ADR's status/supersession note only as needed;
- preserve the old rationale;
- update this index in the same change;
- use canonical decision keys/links where a numeric label would be ambiguous.

Amendments are appropriate only when the original decision remains the same
decision and the amendment can be understood without erasing the historical
rationale. Materially different architecture should normally be a new ADR.

## Architecture inconsistency process

Architecture intent, public contract, and implementation reality are separate
authority domains. If they disagree, do not resolve the conflict by recency.

An unresolved architecture inconsistency must be recorded in the active
repository work item (normally a GitHub issue or PR) with at least:

```text
Concern
Normative authority
Implementation / contract reality
Conflict
Resolution dependency
Status: OPEN | DEFERRED | RESOLVING | RESOLVED
Final resolution
```

Existing Workstream carry-forward (`CF-*`) and architecture-inconsistency
(`AI-*`) registers are discovery/planning evidence, not normative architecture.
During the current reconciliation program their unresolved contents are
consolidated into named Architecture Change Sets (ACS) and Compatibility Gates
(CG). A repository change that resolves such an item should identify the
corresponding ACS/CG in its PR/commit rationale.

A legacy carry-forward proposition is closed only by one of:

- adoption into current source/public contract/current documentation;
- an Accepted ADR;
- explicit rejection/non-carry disposition; or
- an open repository work item when the resolution is intentionally deferred.

Working registers must not be copied wholesale into current architecture
documentation as if they were normative decisions.

## Relationship to explanatory architecture documentation

ADRs record normative decisions. Explanatory architecture documents describe
the current reconciled system but do not supersede ADRs merely by being newer.

The final current/non-current documentation layout is handled separately by the
architecture-documentation migration work. Until that migration is complete,
files under legacy `spec/design/` must not be assumed to be normative solely
because they exist in the repository.
