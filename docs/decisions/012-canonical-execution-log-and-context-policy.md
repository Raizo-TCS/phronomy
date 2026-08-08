# 012 — Canonical Complete Execution Log and Context Policy

## Status

Accepted for the stateful Agent refactor. This decision supersedes the parts of ADR-011 that made the legacy `build_context`/Assembler path the long-term LLM-input authority.

## Decision

Phronomy records the logical execution facts it observes as an append-only Canonical Complete Execution Log. Context selection, pruning and compaction do not rewrite or delete those raw facts. They decide only which representation is materialized into one LLM Call Manifest.

The persistent identity axes have narrow responsibilities:

- `agent_id` identifies the owning Agent.
- `execution_id` identifies one AgentExecution. It is provenance, not a Context-selection atom.
- `llm_call_id` identifies one runtime Provider LLM Call. It is allocated before transport starts and correlates the assistant outcome and its Tool Call batch. It is provenance, not a semantic-compaction boundary.
- `tool_call_id` links one Tool Call to its Tool Result.
- Journal `sequence` is canonical chronology.

No `message_group_id` is introduced. Imported history does not receive synthetic `execution_id` or `llm_call_id`; message order and Tool protocol are preserved, and ambiguous/malformed histories are rejected instead of guessed.

One Provider response is captured as a Phronomy-owned `ProviderCallOutcome` before Agent-owned Tool execution starts. Tool Calls in the canonical log are normalized from that outcome, not from Application callback delivery. Tool Results are correlated by `tool_call_id` and the originating runtime `llm_call_id`.

Context selection is expressed separately through `ContextCandidate`, dependency-aware `ContextSelectionUnit`, `ContextRequest`, `ContextPolicy`, validated `ContextPlan`, and final token-budget validation. Parallel Tool Calls originating in one Provider assistant message and their Tool Results form an atomic protocol unit. Ordinary messages in the same `execution_id` remain independently selectable.

## RubyLLM boundary

Agent-owned Tool execution requires RubyLLM's additive callback contract introduced in RubyLLM 1.15. Phronomy therefore requires `ruby_llm >= 1.15, < 2`.

RubyLLM 1.15 adds the complete assistant message to `Chat#messages` before `before_tool_call` callbacks run. Phronomy captures the immutable Provider outcome at that boundary and raises `ToolCallIntercepted` only as an internal control transfer so approval, suspension, parallel dispatch and durable state remain Phronomy-owned.

## Consequences

- Canonical execution history is independent of the current Context budget or policy.
- Old optional working history may be excluded from a follow-up Manifest without being deleted.
- Tool protocol dependencies are validated independently from semantic selection policy.
- Context Policy can later introduce deterministic derived/compacted records without replacing their raw sources.
- Public custom Context Policy APIs, transaction-boundary restructuring, deterministic compaction, Manifest v2/tool subsets, and legacy Assembler removal remain later phases.
