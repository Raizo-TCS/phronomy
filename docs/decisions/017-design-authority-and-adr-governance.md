# ADR-017: Design Authority and ADR Governance

## Status

Accepted.

## Date

2026-08-23

## Context

Phronomy contains multiple artifact classes that answer different questions:

- ADRs record architecture intent;
- source/runtime behavior records implementation reality;
- public API documentation, `@api` classification, compatibility/contract
  tests and runtime behavior collectively define public/extension contracts;
- RBS represents an already-established typed contract;
- ordinary tests provide regression evidence;
- historical and archived design documents preserve context but may describe
  architecture that is no longer current.

Treating those artifacts as one universal precedence list creates two failure
modes: stale design can be reimplemented because it looks authoritative, or an
accidental implementation change can silently redefine architecture because
it is newer.

The repository also contains two historical ADR files with numeric prefix
`011`. Numeric labels alone therefore cannot provide an unambiguous identity
for every existing decision.

## Decision

### 1. Authority is question-specific

Phronomy does **not** define one universal precedence order for every artifact.

- Accepted and non-superseded ADRs are the normative authority for
  architecture decisions.
- Source code and runtime behavior are the authority for current
  implementation reality. They do not silently amend architecture intent.
- Public APIs and extension SPIs are composite contracts established by
  runtime behavior, `@api` classification, formal API documentation and
  explicit compatibility/contract tests.
- RBS represents a contract that already exists. RBS does not create new
  public semantics or make an internal API public.
- Ordinary implementation tests are regression evidence. A test is an
  architecture/contract authority only when the repository explicitly treats
  it as an architecture guard or compatibility/contract test.
- Historical, Archived and Superseded artifacts are non-normative for current
  architecture.

### 2. Inconsistency is explicit

When normative architecture, public contract and implementation reality
disagree, no artifact wins automatically because it is newer.

The discrepancy is an architecture inconsistency. It must be recorded,
reviewed and resolved explicitly by changing the appropriate architecture
decision, contract, implementation, or combination of them.

The required tracking fields and lifecycle are defined in
[`docs/decisions/README.md`](README.md).

### 3. ADR canonical identity is the filename basename

The canonical key for an ADR is its filename basename:

```text
NNN-kebab-case-slug
```

The numeric prefix is an ordering/display field. Because the repository
contains two legacy `011` decisions, a bare numeric label is not a globally
unique historical key.

The two legacy `011` ADRs remain in place and are distinguished by:

```text
011-build-context-as-single-llm-input-authority
011-delegate-transport-policy-to-adapters
```

New or modified normative references to either decision must use the full
canonical key or an explicit file link.

### 4. Existing decision history is not renumbered

Existing ADR files are not silently renumbered to repair historical numbering
defects. Renumbering changes references and obscures the actual decision
history.

`016-semantic-multi-agent-handoff` is preserved under its existing key even
though it was created before this governance rule was canonicalized.

### 5. New ADR numbers are monotonic and unique

A new ADR receives:

```text
max(existing numeric prefix) + 1
```

at the point the new decision is prepared for merge.

New ADRs:

- use a three-digit numeric prefix;
- do not fill gaps;
- do not reuse any existing prefix;
- update the decision index in the same change.

Concurrent unmerged ADRs that select the same number are resolved by rebasing:
only the not-yet-historical ADR that merges later is renumbered.

This decision follows the rule it establishes: `016` already existed and `017`
was unused, so this Design Authority decision is ADR-017.

### 6. Supersession preserves history

A superseding decision is normally a new ADR.

The superseded ADR remains in the repository with its historical rationale.
Its status/supersession relation and the decision index are updated so the
current authority is unambiguous.

A materially different architecture is not retroactively edited into an old
Accepted ADR merely to make repository text appear internally consistent.

### 7. Working review registers are planning evidence

Carry-forward (`CF-*`), architecture-inconsistency (`AI-*`), Architecture
Change Set (ACS), and Compatibility Gate (CG) artifacts used during the
architecture reconciliation program are not themselves normative ADRs.

They identify work and evidence. Their output becomes repository authority
only through the appropriate Accepted ADR, public contract, source/runtime
implementation, architecture guard, or current explanatory documentation.

Unresolved items that survive a working review must be represented by an
active repository work item or an explicit deferred dependency; they must not
disappear merely because a working document is retired.

### 8. Explanatory architecture documentation is separate

Current explanatory architecture documentation will be organized under a
dedicated canonical entry as part of the documentation-lifecycle migration.

Those documents explain the reconciled architecture. They do not replace the
ADR system as the authority for architecture decisions.

## Repository contract

Contributors making architecture-sensitive changes must:

1. consult [`docs/decisions/README.md`](README.md);
2. identify relevant Accepted/non-superseded ADRs by canonical key;
3. distinguish architecture intent from implementation reality and public
   contract evidence;
4. record unresolved inconsistencies rather than choosing a winner by recency;
5. update ADR status/index relationships when accepting, amending or
   superseding a decision;
6. preserve the public-API composite contract and RBS non-authority rule.

`CONTRIBUTING.md` carries the developer-facing form of this contract.

## Consequences

### Positive

- Current architecture intent has an explicit repository authority model.
- Duplicate historical ADR number `011` no longer makes decision references
  ambiguous.
- New ADR identifiers cannot silently collide.
- Source drift does not silently become architecture.
- Stale ADR text does not silently override implementation reality; conflicts
  are visible and reviewable.
- RBS and ordinary tests cannot accidentally become architecture-definition
  mechanisms.
- Historical decision rationale is preserved.

### Trade-offs

- Architecture-sensitive changes must update an index and sometimes track an
  explicit inconsistency.
- Existing bare references to the legacy numeric label `ADR-011` can remain
  ambiguous in historical material until that material is otherwise touched.
- Accepted ADRs with known inconsistencies remain visible as normative intent
  until an explicit successor is accepted; the inconsistency process is
  therefore required rather than optional.

## Non-goals

This ADR does not:

- reorganize `spec/design/` into the final current/archive documentation tree;
- resolve domain-specific architecture inconsistencies;
- supersede ADR-010, ADR-012, ADR-013, ADR-014, ADR-015 or ADR-016;
- change Runtime behavior, public APIs, persistence formats, or durable data.
