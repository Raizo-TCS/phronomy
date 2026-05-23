# ADR-006: Built-in Guardrail Implementations Are Not Shipped

## Status

Accepted

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
