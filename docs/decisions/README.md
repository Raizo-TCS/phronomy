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
| [`001-rubyllm-as-provider-layer`](001-rubyllm-as-provider-layer.md) | Superseded | No | Superseded by [`027-llm-adapter-provider-boundary`](027-llm-adapter-provider-boundary.md); historical RubyLLM adoption rationale retained. |
| [`002-workflow-context-immutability`](002-workflow-context-immutability.md) | Amended | Yes | `WorkflowContext#merge` remains new-instance semantics; direct generated field writers are EventLoop-owned guarded mutation APIs. |
| [`003-event-loop-singleton`](003-event-loop-singleton.md) | Accepted | Yes | Current until explicitly superseded/refined. |
| [`004-invoke-timeout-is-not-cancellation`](004-invoke-timeout-is-not-cancellation.md) | Superseded | No | Superseded by [`011-delegate-transport-policy-to-adapters`](011-delegate-transport-policy-to-adapters.md). |
| [`005-static-knowledge-class-level-cache`](005-static-knowledge-class-level-cache.md) | Superseded | No | Superseded by [`013-journal-backed-knowledge-as-context-candidates`](013-journal-backed-knowledge-as-context-candidates.md). |
| [`006-no-built-in-guardrails`](006-no-built-in-guardrails.md) | Superseded | No | Superseded by [`019-filter-contract-and-security-boundaries`](019-filter-contract-and-security-boundaries.md); historical minimal-built-in/Guardrail rationale retained. |
| [`007-mcp-is-beta-stability`](007-mcp-is-beta-stability.md) | Accepted | Yes | Current. |
| [`008-orchestrator-uses-os-threads`](008-orchestrator-uses-os-threads.md) | Superseded | No | Superseded by [`010-cooperative-first-concurrency`](010-cooperative-first-concurrency.md). |
| [`009-state-store-abstraction`](009-state-store-abstraction.md) | Superseded | No | Superseded by [`014-unified-persistence-durable-state`](014-unified-persistence-durable-state.md). |
| [`010-cooperative-first-concurrency`](010-cooperative-first-concurrency.md) | Accepted | Yes | Current until explicitly refined/superseded. |
| [`011-build-context-as-single-llm-input-authority`](011-build-context-as-single-llm-input-authority.md) | Superseded | No | Superseded by [`012-canonical-execution-log-and-context-policy`](012-canonical-execution-log-and-context-policy.md). |
| [`011-delegate-transport-policy-to-adapters`](011-delegate-transport-policy-to-adapters.md) | Accepted | Yes | Legacy duplicate numeric prefix; use the full canonical key. |
| [`012-canonical-execution-log-and-context-policy`](012-canonical-execution-log-and-context-policy.md) | Accepted | Yes | Current Journal / Manifest / Context authority. |
| [`013-journal-backed-knowledge-as-context-candidates`](013-journal-backed-knowledge-as-context-candidates.md) | Accepted | Yes | Current persistent Knowledge authority. |
| [`014-unified-persistence-durable-state`](014-unified-persistence-durable-state.md) | Accepted | Yes | Durable-backend and live-owner/no-reload intent remains current; live Agent execution mutation is refined by ADR-024, same-process Agent identity/admission ownership by ADR-025, and same-process Workflow admission/terminal-barrier ordering by ADR-026. Workflow identity terminology is superseded by ADR-020, generic `InvocationContext` / Agent correlation semantics by ADR-021, and concrete FSMSession/Agent-Tool routing identity by ADR-023. |
| [`015-tool-public-facade-and-rbs-boundary`](015-tool-public-facade-and-rbs-boundary.md) | Accepted | Yes | Current Tool façade / extension-SPI / RBS boundary. |
| [`016-semantic-multi-agent-handoff`](016-semantic-multi-agent-handoff.md) | Accepted | Yes | Current semantic Handoff intent; runtime/context-transfer reconciliation is implemented and reflected in current architecture documentation. |
| [`017-design-authority-and-adr-governance`](017-design-authority-and-adr-governance.md) | Accepted | Yes | Repository-wide architecture authority and ADR governance. |
| [`018-durability-guarantees-and-failure-model`](018-durability-guarantees-and-failure-model.md) | Accepted | Yes | Repository-wide durability/concurrency/external-effect guarantee vocabulary and F0-F4/X0 failure model. |
| [`019-filter-contract-and-security-boundaries`](019-filter-contract-and-security-boundaries.md) | Accepted | Yes | Current Filter transform/block and bounded PromptInjectionFilter/isolation boundaries; the follow-up review adds no fourth Context Filter call site and places semantic Context trust in Application ContextPolicy. |
| [`020-canonical-workflow-instance-identity`](020-canonical-workflow-instance-identity.md) | Accepted | Yes | Canonical logical/durable Workflow identity and CG-01 clean-break migration. |
| [`021-generic-agent-invocation-identity-removal`](021-generic-agent-invocation-identity-removal.md) | Accepted | Yes | Removes generic Agent/InvocationContext identity and canonical Journal `correlation_id`; CG-02 is closed, with targeted legacy durable-key read compatibility and no eager rewrite. |
| [`022-agent-execution-parent-identity-and-runtime-routing-boundary`](022-agent-execution-parent-identity-and-runtime-routing-boundary.md) | Accepted | Yes | Canonicalizes Agent-owned Tool/approval logical parent as `execution_id`; CG-03a is reconciled, ADR-023 supplies incarnation routing, and ADR-024 supplies EventLoop result/live-state authority. |
| [`023-fsm-session-incarnation-identity-and-routing`](023-fsm-session-incarnation-identity-and-routing.md) | Accepted | Yes | FSMSession-owned incarnation identity, session-local Agent/Tool/Multi-Agent routing, and stale-target drop remain current. Its transitional Workflow identity-reservation/admission bridge is superseded by ADR-026; Agent result authority is completed by ADR-024. |
| [`024-event-loop-single-writer-agent-runtime`](024-event-loop-single-writer-agent-runtime.md) | Accepted | Yes | EventLoop is the single writer of Phronomy-managed live Agent execution state; removes Activation/ActivationRegistry and defines operation-specific Offload result application with current FSM + semantic-ID authority. |
| [`025-process-local-agent-ownership-and-runtime-admission`](025-process-local-agent-ownership-and-runtime-admission.md) | Accepted | Yes | One mutable live Agent owner per `agent_id` per Runtime; EventLoop is the primary same-process top-level admission authority while Persistence admission remains durable defense. |
| [`026-workflow-runtime-admission-and-durable-terminal-barrier`](026-workflow-runtime-admission-and-durable-terminal-barrier.md) | Accepted | Yes | EventLoop-owned opaque Workflow admission owner, admission-before-hydration ordering, and FSMSession-integrated durable terminal save barrier with fail-closed uncertain outcomes. |
| [`027-llm-adapter-provider-boundary`](027-llm-adapter-provider-boundary.md) | Accepted | Yes | Phronomy-owned Provider-call extension boundary; RubyLLM is the default adapter/integration while current input materialization remains RubyLLM-specific. |
| [`028-preparing-recovery-replay-contract`](028-preparing-recovery-replay-contract.md) | Accepted | Yes | Adds replay-safe same-`execution_id` recovery for durably admitted Agent `:preparing` executions when replayability is durably established; unsupported Runtime-only dependencies fail closed. |

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

Current explanatory architecture starts at
[`docs/architecture.md`](../architecture.md). Non-current design snapshots are
segregated under `docs/archive/design/` and are non-normative. Explanatory
architecture documents describe the reconciled current system but do not
supersede ADRs merely by being newer.
