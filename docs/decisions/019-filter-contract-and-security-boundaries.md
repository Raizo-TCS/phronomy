# ADR-019: Filter Contract and Security Boundaries

## Status

Accepted.

## Date

2026-08-23

## Context

Phronomy's live implementation and public API have moved from the former
`Guardrail::*` hierarchy to a unified `Phronomy::Filter::Base` model.

The old architecture described separate `InputGuardrail` and
`OutputGuardrail` base classes, `GuardrailError`, `*_guardrail` registration
APIs, and a built-in PII detector. Those APIs no longer exist. Current source
instead exposes explicit Filter call sites for input, output, and Tool
results, with one Filter abstraction that can transform a value or reject it.

ADR-006 preserved useful policy intent — especially avoiding a false sense of
complete generic security and keeping domain-specific policy
application-owned — but its normative API vocabulary still described the
removed Guardrail hierarchy. Leaving that ADR normative makes architecture
authority disagree with the current Filter contract.

This ADR supersedes ADR-006 for the current Filter/security-policy
architecture while preserving ADR-006 as decision history.

## Decision

### 1. `Filter::Base` is the current policy-interception abstraction

The current public abstraction is:

```ruby
Phronomy::Filter::Base
```

A Filter receives a value at an explicitly defined call site and may:

1. return the original value;
2. return a transformed value; or
3. reject the value by raising `Phronomy::FilterBlockError`, normally through
   `Filter::Base#block!`.

A Filter is not divided into InputFilter/OutputFilter subclasses. The same
Filter instance may be registered at more than one call site when that is
appropriate for the application.

### 2. Filter call sites remain explicit

Current Agent Filter registration supports distinct call sites:

```text
input
output
Tool result
```

Multiple Filters at one call site run in registration order. A blocking
Filter short-circuits later processing through `FilterBlockError`.

The call-site distinction is semantically important. A Filter registered for
one site does not silently become a universal content-inspection hook.

### 3. Input Filter means raw invocation-input filtering today

The current `input_filter` / `add_input_filter` path applies to raw invocation
input before later Context assembly.

It does **not** automatically inspect every value that may later contribute to
an LLM input, including all Knowledge, retrieval results, Tool-derived
Context, or `before_llm_input` `segment_candidates`.

This ADR does not decide whether Phronomy should add a dedicated
Context-candidate inspection point. That broader trust-boundary question
remains the separate Filter/Security Boundary review.

### 4. `PromptInjectionFilter` is a bounded heuristic baseline

Phronomy may provide the lightweight built-in:

```ruby
Phronomy::Filter::PromptInjectionFilter
```

as a convenience baseline for common prompt-injection patterns.

This Filter is a heuristic pattern detector. Its presence does not mean:

- all prompt injection is detected;
- every untrusted Context source is automatically inspected;
- Filter registration establishes an LLM security sandbox; or
- Phronomy provides a complete content-security guarantee.

Applications remain responsible for selecting appropriate Filter call sites
and for additional domain-specific controls.

### 5. Generic built-in PII policy is not a Phronomy core guarantee

The removed `PIIPatternDetector` architecture is not carried forward.

PII definitions, locale-specific identifiers, compliance requirements and
transformation/rejection policy are application/domain responsibilities
unless a future explicit architecture decision introduces a new contract.

Applications can implement these policies as `Filter::Base` subclasses or
application-owned components.

### 6. Filter/approval/offload are not process-security isolation

Filter, Tool approval, EventLoop/OffloadPool execution boundaries and
application authorization are distinct mechanisms.

None of them, by itself, promises:

- OS process isolation;
- container isolation;
- filesystem/network sandboxing;
- privilege separation; or
- containment of arbitrary malicious Tool/application code.

If an application needs those properties, the isolation mechanism is
application/deployment-owned unless Phronomy later defines a specific
sandbox SPI.

### 7. Removed Guardrail contracts stay removed

The following legacy architecture is not a current compatibility contract and
must not be reintroduced merely for naming compatibility:

```text
Phronomy::Guardrail::Base
Phronomy::Guardrail::InputGuardrail
Phronomy::Guardrail::OutputGuardrail
Phronomy::GuardrailError
add_input_guardrail
add_output_guardrail
input_guardrail
output_guardrail
```

Current code uses `Filter::Base`, `FilterBlockError`, and explicit
`*_filter` registration APIs.

### 8. Historical Guardrail documentation remains historical

`docs/archive/design/archived/09_guardrails.md` records the removed Guardrail design. It is
non-normative and is not rewritten into current Filter architecture.

Its physical move to the repository archive is part of the final
documentation-lifecycle migration. Until that move, the file must carry an
explicit ARCHIVED/non-normative notice so retrieval does not mistake it for
current architecture.

### 9. Deferred security-boundary questions remain deferred

This decision deliberately does not settle the broader Filter/Security Boundary review, including:

- whether and where all untrusted Context candidates require inspection;
- whether a dedicated pre-Manifest Context inspection stage is needed;
- stronger PromptInjectionFilter guarantees;
- Tool sandbox architecture;
- or a new public security-policy SPI.

Those questions must not be smuggled into the current Filter contract by
changing call-site semantics implicitly.

## Follow-up security-boundary review

The subsequent D02-F02 reconciliation review closed the Context-inspection
question without broadening the Filter SPI:

- no fourth `context_filter` / `add_context_filter` call site is added;
- Application `ContextPolicy` is the semantic trust/selection authority for
  one LLM Call's typed Context;
- Framework validation remains structural/integrity validation rather than
  arbitrary semantic filtering;
- Tool approval remains authorization rather than sanitization or sandboxing;
- OS/process/container/filesystem/network isolation remains an
  Application/deployment concern.

The current explanatory boundary is
[`docs/architecture/security-boundaries.md`](../architecture/security-boundaries.md).

## Supersession

This ADR supersedes
[`006-no-built-in-guardrails`](006-no-built-in-guardrails.md) as the normative
Filter/security-policy architecture.

ADR-006 remains preserved as history explaining the earlier minimal-built-in
policy and its later prompt-injection exception.

## Consequences

### Positive

- normative architecture now matches the live Filter model;
- old Guardrail class names cannot be mistaken for current public contracts;
- useful "avoid false confidence" policy intent from ADR-006 is retained;
- Filter behavior and security-isolation guarantees remain distinct;
- current raw-input filtering is not falsely described as universal Context
  inspection; and
- broader security-boundary design can proceed without being pre-decided by
  terminology cleanup.

### Trade-offs

- historical documentation continues to contain old Guardrail names until the
  documentation archive migration physically moves it;
- applications needing PII/domain policy continue to supply that policy
  themselves; and
- the built-in PromptInjectionFilter remains intentionally modest rather than
  a complete security solution.

## Non-goals

This ADR does not:

- change Filter runtime behavior or ordering;
- change the current raw-input `input_filter` placement;
- automatically apply input Filters to Knowledge/RAG/hook Context;
- add a Context-candidate inspection API;
- add OS/process/container Tool sandboxing;
- change Tool approval semantics;
- change Persistence or durable representation;
- make Filter stability stronger than the public feature catalog currently
  states; or
- perform the final `spec/design/*` path migration.
