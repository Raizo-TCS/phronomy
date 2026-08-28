> **CURRENT explanatory architecture**
>
> This document describes the reconciled current Phronomy system. Normative
> architecture decisions remain in the [ADR index](../decisions/README.md);
> source/runtime behavior remains implementation reality and does not silently
> amend an ADR.

# Security Boundaries

## 1. Responsibility model

Phronomy deliberately keeps content-policy interception, Context semantic trust,
Tool authorization, and execution isolation as separate mechanisms.

```text
raw invocation input
    -> input_filter

Tool result
    -> tool_result_filter

possible LLM Context material
    -> ContextPolicyInput
    -> Application ContextPolicy
         semantic selection / omission / derivation /
         source-aware trust/security policy
    -> ContextPlan
    -> Framework structural validation
    -> LLMInputManifest

final Agent output
    -> output_filter
```

No mechanism above is an all-purpose security layer.

The current Filter contract is
[ADR-019](../decisions/019-filter-contract-and-security-boundaries.md).

## 2. Explicit Filter call sites

`Phronomy::Filter::Base` may transform a value or block processing through
`FilterBlockError`.

Framework Filter call sites are explicit:

```text
input
output
Tool result
```

A Filter registered at one call site is not silently applied to every value that
may later reach an LLM.

In particular, Phronomy does **not** add a fourth `context_filter` /
`add_context_filter` Framework call site.

## 3. Context semantic trust belongs to Application Policy

LLM Context is domain-dependent: content that is suspicious in one application
may be exactly the content another Agent is supposed to analyze.

The Framework therefore owns structural/integrity validation, while
Application-defined `ContextPolicy` owns semantic trust decisions for one LLM
Call.

An Application Policy may:

- inspect typed category/provenance/metadata;
- omit optional material;
- fail preparation when required material is unacceptable;
- derive sanitized/redacted current-call material;
- retrieve/rerank content; or
- call a `Filter::Base` instance internally as ordinary Ruby policy logic.

There is no separate Framework invocation guarantee when a Policy chooses to
compose a Filter internally.

## 4. Non-destructive transformation

Context trust policy must not rewrite canonical Journal history.

For optional content, transformation follows the current Context model:

```text
canonical/source item remains intact
        |
Policy omits it for this call
        +
Policy creates derived current-call item
        |
ContextPlan -> Manifest
```

Required material is protected by Framework invariants. A Policy cannot silently
drop a required source item; if the required input cannot be accepted, Context
preparation fails.

## 5. Framework validation is not semantic filtering

After Policy selection, Phronomy validates:

- typed category/item identity;
- required material;
- Framework-owned metadata/provenance authority;
- conversation and Tool-call/result dependency structure;
- effective Tool wiring;
- canonical representation; and
- final token budget.

These checks establish integrity, not truth, safety, trustworthiness, or domain
appropriateness of arbitrary content.

## 6. Knowledge/RAG boundary

Phronomy does not add a mandatory semantic security hook to `add_knowledge`.
Retrieval-source validation and ingestion policy remain Application/Tool
responsibilities.

Per-call use of Knowledge is decided by Context Policy.

See [Knowledge and RAG](knowledge-and-rag.md).

## 7. Tool approval is authorization, not sanitization

Tool approval controls whether a side-effecting/capability operation may execute.
It does not sanitize arbitrary Tool arguments/results, establish prompt-injection
safety, or create an OS sandbox.

Authorization and content policy are separate concerns.

## 8. PromptInjectionFilter

`Phronomy::Filter::PromptInjectionFilter` is an optional bounded heuristic for
common patterns.

It does not guarantee detection of all prompt injection, automatically inspect
all Context sources, or turn LLM execution into a security sandbox.

Applications remain responsible for domain-specific controls.

## 9. Execution placement is not isolation

EventLoop, OffloadPool, cooperative cancellation, and Tool `execution_mode`
describe execution/lifecycle mechanics.

They do not provide:

- OS process isolation;
- container isolation;
- filesystem or network sandboxing;
- privilege separation; or
- containment of arbitrary malicious Application/Tool code.

Those properties are Application/deployment responsibilities unless a future
explicit isolation subsystem is accepted.

## 10. No new security-policy SPI

This architecture does not add:

```text
context_filter
SecurityContext
TrustLevel
security metadata authority API
sandbox SPI
```

Arbitrary item `metadata` remains Application data except for
Framework-reserved control keys. Applications must not treat arbitrary metadata
as a Framework-certified trust assertion.
