# ADR-006: Minimal Built-in Guardrail Implementations

## Status

Amended (see Amendment section below)

## Context

Phronomy provides `Guardrail::InputGuardrail` and `Guardrail::OutputGuardrail`
as base classes. The question is whether to ship a library of built-in
implementations (e.g., prompt injection detector, PII scanner, toxic content
filter, word-count limit).

Arguments for built-ins:
- Lower barrier to entry; users get safety out of the box.
- Consistent quality baseline across applications.

Arguments against:
- Guardrail correctness is highly domain-specific. A PII pattern for US Social
  Security Numbers is irrelevant to a Japanese-language application.
- Prompt injection patterns evolve rapidly; a built-in detector would require
  frequent updates and could give false confidence.
- Shipping third-party detection libraries (NLP, regex banks) as hard
  dependencies increases gem weight and potential supply-chain risk.
- The guardrail interface is intentionally minimal (`check(input)` / `fail!`).
  Custom implementations are one-class affairs.

## Decision

Phronomy ships no built-in guardrail implementations. The framework provides:

1. `Guardrail::InputGuardrail` and `Guardrail::OutputGuardrail` base classes
   with `check` and `fail!` hooks.
2. Documentation and examples showing how to implement custom guardrails.

Users are responsible for implementing domain-specific guardrail logic.

## Consequences

**Positive:**
- No false sense of security from a generic built-in that does not match the
  application's actual threat model.
- Gem remains dependency-light.
- The interface is stable regardless of how the threat landscape evolves.

**Negative / Tradeoffs:**
- Users must implement their own guardrails from scratch. Providing a cookbook
  of example patterns in the README partially mitigates this.

## Amendment — `PromptInjectionGuardrail` Added

After the original decision was accepted, `Guardrail::PromptInjectionGuardrail`
was introduced as the **one exception** to the "no built-ins" rule.

**Rationale for the exception:**
- Prompt injection patterns are broadly applicable across almost all LLM
  applications regardless of domain, unlike PII patterns which are locale-specific.
- A lightweight, pure-regex implementation has no third-party dependency and
  adds negligible gem weight.
- It serves as a documented reference implementation that users can subclass with
  `extra_patterns:` to extend.

**Scope of the exception:**
Only prompt-injection detection is provided as a built-in. PII scanning,
content classification, and toxic-content filtering remain out of scope per the
original decision.
