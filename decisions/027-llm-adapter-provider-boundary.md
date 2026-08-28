# ADR-027: Phronomy-Owned LLM Adapter and RubyLLM Default Provider Boundary

## Status

Accepted

## Context

ADR-001 selected RubyLLM as Phronomy's LLM provider layer. Its original
Decision text also encoded an implementation boundary in which Agent code and
the legacy Chain API called `RubyLLM.chat` directly.

The current architecture has evolved:

```text
Phronomy Agent / Context / Manifest
        |
        v
RubyLLMMaterializer
        |
        v
Phronomy::LLMAdapter::Base
        |
        v
configured adapter
(default: Phronomy::LLMAdapter::RubyLLM)
```

Phronomy now owns Agent lifecycle, Runtime coordination, canonical Journal /
Context Policy / Manifest semantics, durable execution state, and the
framework-owned asynchronous/offload bridge around Provider calls.

At the same time, the current materialization path is still RubyLLM-specific:
the LLMAdapter SPI receives the configured/materialized chat runtime object.
Making the Provider-call boundary replaceable does not by itself make the
complete LLM-input materialization pipeline provider-neutral.

The public LLMAdapter SPI is currently classified Beta. Architecture
reconciliation must not silently promote its API stability.

## Decision

1. Phronomy owns Agent lifecycle, Context/Manifest authority, Runtime
   coordination, and durable execution semantics. These responsibilities are
   not delegated to `RubyLLM::Agent`.
2. `Phronomy::LLMAdapter::Base#complete` and `#stream` are the public
   Provider-call extension boundary. Phronomy owns the framework-side
   asynchronous/offload wrappers around that synchronous adapter contract.
3. `Phronomy::LLMAdapter::RubyLLM` remains the default configured LLM adapter
   and RubyLLM remains Phronomy's default Provider integration.
4. A custom LLMAdapter may replace Provider-call behavior, but the LLMAdapter
   SPI does not imply that the complete input-materialization pipeline is
   Provider-neutral. The current Agent pipeline still materializes canonical
   LLM input through RubyLLM-specific runtime objects.
5. Provider transport timeout, retry, backoff, jitter, and rate-limit handling
   remain adapter/provider-client responsibilities, consistent with
   [`011-delegate-transport-policy-to-adapters`](011-delegate-transport-policy-to-adapters.md).
6. This decision does not expand Phronomy scope merely because RubyLLM or
   another Provider exposes additional features.
7. This decision does not change the existing API stability classification of
   the LLMAdapter SPI.

## Consequences

### Positive

- The normative architecture matches the current Phronomy-owned Agent /
  Context / Manifest pipeline.
- RubyLLM remains the default integration without making direct RubyLLM calls
  the Phronomy extension contract.
- Applications can supply a custom call adapter through one explicit boundary.
- Runtime/offload semantics stay Phronomy-owned while transport policy stays
  adapter-owned.
- Provider-call replaceability is not confused with full materialization
  neutrality.

### Tradeoffs

- Custom adapters currently receive Phronomy's materialized chat runtime object
  and therefore may still depend on the RubyLLM-shaped materialization boundary.
- Replacing the current RubyLLM-specific materializer would require a separate
  architecture/API decision if Phronomy later wants end-to-end Provider-neutral
  materialization.
- The Beta LLMAdapter SPI may still evolve according to the repository's
  compatibility policy.

## Supersession

This decision supersedes
[`001-rubyllm-as-provider-layer`](001-rubyllm-as-provider-layer.md).

ADR-001 remains preserved as historical rationale for adopting RubyLLM, but its
direct-call boundary is no longer normative.
