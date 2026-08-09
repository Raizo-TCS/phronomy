# Context management design

> **Current design contract — Manifest-first**
>
> This document replaces the legacy `build_context` / mutable-message trimming model.
> Historical design discussions remain in ADR-011, which is superseded by ADR-012.

## Authority model

```text
Observed execution facts
        ↓
Canonical append-only Agent Journal
        ↓
ContextCandidateResolver
        ↓
Context Policy
        ↓
validated ContextPlan
        ↓
Canonical LLMInputManifest
        ↓
RubyLLMMaterializer
        ↓
RubyLLM / Provider
```

The Journal and Manifest have different authority:

- **Journal**: canonical record of logical execution facts observed by Phronomy.
- **Manifest**: canonical logical input selected for one specific LLM Call.
- **Runtime projection**: derived from the Manifest; it is not a new source of truth.

Context selection may omit prior records from one Manifest, but it must not delete or rewrite raw Journal history.

## Current public-facing knobs

Agent definitions may configure:

```ruby
class MyAgent < Phronomy::Agent::Base
  agent_definition id: "my-agent", version: 1
  model "gpt-4o"
  context_window 128_000
  max_output_tokens 4_096
  instructions "..."
  tools(
    SearchTool => nil,
    WeatherTool => "weather"
  )
end
```

`context_overhead` is not part of the current contract. Mandatory instructions, the current input, Tool definitions and selected context are budgeted from the actual canonical values.

## Context Policy

The default policy uses these framework-owned parts:

- `ContextParts::UnitBuilders::DependencyAwareUnitBuilder`
- `ContextParts::Requirements::RequiredContextResolver`
- `ContextParts::Selectors::RecentFirstSelector`
- `ContextParts::Budget::TokenBudgetPacker`
- `ContextPlanValidator`
- `ContextParts::Validators::FinalBudgetValidator`

Policy chooses optional context. Framework validators retain authority over protocol dependency closure, required coverage and final token-budget validity.

`execution_id` is provenance, not an atomic selection boundary.

## Tool protocol dependency

Assistant Tool Calls and the Tool messages that answer them must not be selected into a malformed protocol sequence. Dependency grouping is based on actual Tool protocol identity (`tool_call_id`) and current call relationships, not on a synthetic conversation-group identifier.

## Import

Imported user/assistant/Tool messages preserve the logical message boundaries supplied by the Import API. Phronomy does not invent synthetic `llm_call_id` or message-group IDs merely to make imported history fit runtime-origin records.

Malformed Tool protocol data is rejected; valid imported message structure is not flattened and guessed back together.

## Token budget

`Phronomy::LlmContextWindow::TokenBudget` is a private arithmetic value object:

```ruby
budget = Phronomy::LlmContextWindow::TokenBudget.new(
  context_window: 128_000,
  max_output_tokens: 4_096
)

budget.effective_input_limit
budget.available(used: 10_000)
```

Model lookup and Agent-specific resolution belong to `Agent::TokenBudgetResolver`.

The final assembled Manifest is validated after policy selection. A policy cannot bypass the final budget check.

## before_llm_input

`before_llm_input` may return `LLMInputPatch` with model-config changes or logical `segment_candidates`. The hook does not receive mutable RubyLLM message history and must not mutate the canonical Journal.

## Legacy contracts

The following are removed from the active architecture:

- `Agent::Base#build_context`
- `Agent::Base#trim_messages`
- Agent-level mutable-message compaction as the LLM input authority
- `context_overhead`
- `Phronomy::LlmContextWindow::Assembler`
- `Phronomy::LlmContextWindow::ContextVersionCache`

See ADR-011 for historical rationale and ADR-012 for the current authority model.
