# 012 — Canonical Complete Execution Log and Context Policy

## Status

Accepted for the stateful Agent refactor. This decision supersedes the parts of ADR-011 that made the legacy `build_context`/Assembler path the long-term LLM-input authority.

## Decision

Phronomy records the logical execution facts it observes as an append-only Canonical Complete Execution Log. Context selection, pruning and compaction do not rewrite or delete those raw facts. They decide only which representation is materialized into one LLM Call Manifest.

Journal and Manifest are separate authorities:

- **Journal** is the authoritative record of logical execution facts that Phronomy observed.
- **Manifest** is the authoritative record of the logical input fixed for one particular LLM Call.
- Runtime Projection is derived from the Manifest and must not add semantic content that the Manifest did not select.

The persistent identity axes have narrow responsibilities:

- `agent_id` identifies the owning Agent.
- `execution_id` identifies one AgentExecution. It is provenance, not a Context-selection atom.
- `llm_call_id` identifies one runtime Provider LLM Call. It is allocated before transport starts and correlates that call's outcome. It is provenance, not a semantic-compaction boundary.
- `tool_call_id` links an assistant message's Tool Call with the corresponding Tool execution/message.
- Journal `sequence` is canonical chronology.

No `message_group_id`, import-only source provenance ID, or synthetic imported `execution_id` / `llm_call_id` is introduced.

### Message preservation

A logical message that Phronomy receives is not flattened merely to make later Context assembly convenient.

- A Provider assistant response is captured as one complete assistant message containing its observable `content` and all Tool Calls.
- An imported assistant message is journaled as one assistant message with the structure supplied by the Import contract.
- A Tool value returned by Phronomy Tool execution is an execution fact (`tool_result`).
- The Tool-role message actually appended to the LLM conversation is a separate logical fact (`tool_message`).
- Imported Tool-role messages are journaled directly as `tool_message` records; Phronomy does not invent a separate raw Tool execution result for an execution it did not observe.

The Journal therefore does not need to infer or reconstruct a source message boundary that Phronomy already observed. Context Policy can inspect Tool Call IDs contained in an assistant message and form protocol-safe selection units with the corresponding Tool messages.

### Import boundary

The application supplying imported history is responsible for satisfying Phronomy's Import contract. Phronomy interprets valid input according to that contract and rejects only data that is invalid under the contract, such as unsupported roles, missing Tool Call IDs, orphan/duplicate Tool results, unresolved Tool calls, or unsupported attachments.

Phronomy must not reject an otherwise valid input merely because an internal flattened representation would lose information. In particular, two separately supplied assistant messages remain two separate Journal messages.

### Manifest boundary

The Manifest fixes what one LLM Call will actually receive after Context Policy selection. A historical raw Tool return value and the Tool message produced from it are not interchangeable: the raw result belongs to the execution log, while the message selected for an LLM Call belongs to the Manifest input path.

One Provider response is captured as a Phronomy-owned `ProviderCallOutcome` before Agent-owned Tool execution starts. The canonical assistant-message record is produced from that outcome, not from Application callback delivery.

Context selection is expressed separately through `ContextCandidate`, dependency-aware `ContextSelectionUnit`, `ContextRequest`, `ContextPolicy`, validated `ContextPlan`, and final token-budget validation. An assistant message containing Tool Calls and the corresponding Tool messages form an atomic protocol unit. Ordinary messages in the same `execution_id` remain independently selectable.

## RubyLLM boundary

Agent-owned Tool execution requires RubyLLM's additive callback contract introduced in RubyLLM 1.15. Phronomy therefore requires `ruby_llm >= 1.15, < 2`.

RubyLLM 1.15 adds the complete assistant message to `Chat#messages` before `before_tool_call` callbacks run. Phronomy captures the immutable Provider outcome at that boundary and raises `ToolCallIntercepted` only as an internal control transfer so approval, suspension, parallel dispatch and durable state remain Phronomy-owned.

## Consequences

- Canonical execution history is independent of the current Context budget or policy.
- Import and runtime histories converge on the same canonical assistant/tool-message model without synthetic grouping identity.
- Old optional working history may be excluded from a follow-up Manifest without being deleted.
- Raw Tool results remain available as execution facts even when the corresponding Tool message is omitted from a later Manifest.
- Tool protocol dependencies are validated independently from semantic selection policy.
- Context Policy can later introduce deterministic derived/compacted records without replacing their raw sources.
- Public custom Context Policy APIs, transaction-boundary restructuring, deterministic compaction, Manifest v2/tool subsets, and legacy Assembler removal remain later phases.
