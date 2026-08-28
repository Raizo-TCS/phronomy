# ADR-001: Use RubyLLM as the LLM Provider Layer

## Status

Superseded

Superseded by
[`027-llm-adapter-provider-boundary`](027-llm-adapter-provider-boundary.md).
The historical rationale for adopting RubyLLM is preserved below; the direct
Provider-call boundary described by this ADR is no longer normative.

## Context

Phronomy needs to send prompts to large language models and receive structured
responses. The options were:

1. Implement provider clients directly (OpenAI, Anthropic, Google, etc.)
2. Vendor an existing Ruby abstraction library
3. Treat providers as a pluggable adapter with a thin wrapper

Implementing provider clients directly would require maintaining authentication,
retry logic, streaming, and model versioning for each provider — significant
ongoing maintenance cost. The Ruby ecosystem has a maturing option in RubyLLM,
which provides a unified interface for multiple providers and handles streaming,
tool call serialization, and response parsing.

## Decision

Phronomy delegates all LLM provider communication to the `ruby-llm` gem.
`Phronomy::Agent::Base` and `Phronomy::Chain::LLMChain` call `RubyLLM.chat`
(or equivalent) rather than provider SDKs directly.

## Consequences

**Positive:**
- Provider switching is a configuration change, not a code change.
- Streaming, tool call parsing, and multi-modal input handling are inherited
  from RubyLLM without re-implementation.
- The phronomy codebase stays focused on agent/workflow orchestration.

**Negative / Tradeoffs:**
- Phronomy's LLM feature surface is bounded by what RubyLLM exposes. Provider
  capabilities not yet supported by RubyLLM are unavailable without a custom
  adapter.
- Bugs or breaking changes in RubyLLM require downstream fixes in phronomy.
- Error types from providers are wrapped in RubyLLM errors; phronomy re-wraps
  them again (see `Agent::Concerns::ErrorTranslation`).
