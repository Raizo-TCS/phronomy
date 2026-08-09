# Context management design

> **Current design contract — Manifest-first**
>
> This document replaces the legacy `build_context` / mutable-message trimming
> model. Historical design discussions remain in superseded ADRs.

## Authority model

```text
Observed execution facts / registered Knowledge
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

- **Journal**: canonical record of logical execution facts and persistent Agent Knowledge.
- **Manifest**: canonical logical input selected for one specific LLM Call.
- **Runtime projection**: derived from the Manifest; it is not a new source of truth.

Context selection may omit prior records from one Manifest, but it must not
delete or rewrite raw Journal history.

## Current public-facing knobs

Agent definitions may configure model, provider, instructions, Tool definitions
and token-window overrides. Persistent Knowledge belongs to Agent instances,
not Agent classes:

```ruby
agent = MyAgent.new(
  knowledge: [
    "Customer tier: enterprise",
    "Policy: external uploads require malware scanning."
  ]
)

agent.add_knowledge("Customer locale: ja-JP")
```

`context_overhead` is not part of the current contract. Mandatory instructions,
current input and Tool definitions are budgeted from their actual canonical
values. Optional candidates are packed by Context Policy.

## Context Policy

The default policy uses framework-owned parts including:

- `ContextParts::UnitBuilders::DependencyAwareUnitBuilder`
- `ContextParts::Requirements::RequiredContextResolver`
- `ContextParts::Selectors::RecentFirstSelector`
- `ContextParts::Budget::TokenBudgetPacker`
- `ContextPlanValidator`
- `ContextParts::Validators::FinalBudgetValidator`

Policy chooses optional Context. Framework validators retain authority over
protocol dependency closure, required coverage and final token-budget validity.

`execution_id` is provenance, not an atomic selection boundary.

## Knowledge

Knowledge is one candidate category. Phronomy does not distinguish Static,
Entity or RAG Knowledge classes.

Persistent Knowledge is stored as append-only Journal records with
`kind: :knowledge`. It is excluded from the public conversation transcript but
included in the Context candidate projection.

Knowledge is optional by default. Being Knowledge does not make a segment
mandatory. If an application requires content to be present on every call, it
must express that requirement as instructions, required coverage or an
appropriate Context Policy decision.

`clear_knowledge!` appends a logical reset marker. Earlier Knowledge records
remain in the Journal but are no longer eligible for future Context selection.
`reset_context!` resets both transcript eligibility and Knowledge eligibility.

## before_llm_input

`before_llm_input` may return `LLMInputPatch` with model-configuration changes
or logical `segment_candidates`.

Per-call segment candidates are not persisted. They enter the same Context
Policy request as persistent/history candidates and may therefore be omitted by
policy when optional and over budget. The hook does not receive mutable RubyLLM
message history and must not mutate the Journal.

## Tool protocol dependency

Assistant Tool Calls and the Tool messages that answer them must not be selected
into a malformed protocol sequence. Dependency grouping is based on actual Tool
protocol identity (`tool_call_id`) and current call relationships, not on a
synthetic conversation-group identifier.

## Import

Imported user/assistant/Tool messages preserve the logical message boundaries
supplied by the Import API. Phronomy does not invent synthetic `llm_call_id` or
message-group IDs merely to make imported history fit runtime-origin records.

Malformed Tool protocol data is rejected; valid imported message structure is
not flattened and guessed back together.

## Token budget

`Phronomy::LlmContextWindow::TokenBudget` is an arithmetic value object used by
Agent Context assembly. Model lookup and Agent-specific resolution belong to
`Agent::TokenBudgetResolver`.

The final assembled Manifest is validated after policy selection. A policy
cannot bypass the final budget check.

## Legacy contracts

The following are removed from the active architecture:

- `Agent::Base#build_context`
- `Agent::Base#trim_messages`
- Agent-level mutable-message compaction as LLM-input authority
- `context_overhead`
- `Phronomy::LlmContextWindow::Assembler`
- `Phronomy::LlmContextWindow::ContextVersionCache`
- `Knowledge::Base`, `StaticKnowledge`, `EntityKnowledge`
- `static_knowledge*` class APIs

See ADR-012 for the Journal/Manifest authority model and ADR-013 for persistent
Knowledge semantics.
