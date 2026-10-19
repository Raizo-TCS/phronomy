# LLM continuation metadata preservation

This correction follows [ADR-066](../decisions/066-llm-and-tool-operation-contracts.md).
It does not change the LLM/Tool/Agent ownership decision, add a dependency to the
contract, or teach Agent a provider wire format.

## Problem and contract

The RubyLLM backend converted SDK responses into Phronomy Response values without
their reasoning data. A later model turn therefore lost information RubyLLM could
otherwise replay. Saved assistant records already contained Message metadata, but
RuntimeInput reconstructed only model_id. Explicit Message imports dropped the
metadata too. These were separate losses along the same conversation path.

C09 Message/Response metadata remains immutable canonical JSON. Backend-owned
continuation data accompanies its assistant message through a Tool round, Journal
serialization, recovery and explicit Phronomy-message import. Agent preserves the
value without inspecting its backend keys. Metadata does not authorize a Tool,
change context selection, become answer content or become arbitrary SDK options.
Record/control metadata remains distinct from metadata inside an assistant payload.

The concrete RubyLLM backend owns the ruby_llm_continuation namespace, format
version 1, and conversion of SDK thinking text/signature and raw_reasoning. It
reconstructs those SDK options only inside the backend. RubyLLM still owns wire
format rendering; no SDK class or provider registry is patched for this fix.
No thinking toggle, extra model call, fallback, retry, sampling change or Tool
execution is introduced. Existing Tool thought_signature behavior is unchanged.

Streaming's final Response retains the same continuation data. Public content
chunks remain answer chunks; this change adds no reasoning-display event API.
SDK token usage semantics are unchanged.

## Replay compatibility

The backend records the requested model ID, provider, selected protocol name and
a SHA-256 of the API base. The endpoint itself and credentials are not stored in
the envelope. Reuse requires an exact match of this scope and format version.
An incompatible scope/version raises ConfigurationError before sending the next
model request. State is neither silently discarded nor sent to a different target.
Malformed envelopes fail explicitly. Legacy messages without the envelope remain
usable; missing historical reasoning cannot be reconstructed.

This conservative equality check is not a claim that all identical endpoints are
semantically unchanged, or that different models can never share reasoning. It
does not detect server runtime/template changes behind one URL, account changes,
or model replacements behind one model ID. Cross-model/provider reasoning
conversion is outside this correction.

Handoff continues to use its existing context selection policy. If a selected
assistant message carries this state, a same-scope target can replay it and a
different-scope RubyLLM target rejects it. Applications requiring transfer across
incompatible scopes must intentionally select/derive portable context using the
existing context policy; they must not forge the scope or treat metadata as
authority. Other backend implementations own their own metadata conventions.

## Persistence and compatibility

There is no DB schema change, new SDK object in storage, or changed public method
signature. RuntimeInput restores the canonical metadata Hash and uses historical
top-level model_id only when metadata does not already contain it. Canonical
metadata is authoritative if both representations exist. Missing metadata means
an empty Hash; malformed non-Hash metadata is rejected.

ContextImporter preserves explicitly supplied canonical Message metadata. It does
not inspect an externally supplied RubyLLM object's thinking field; converting
SDK-specific external histories remains a backend-boundary concern, not a new
Agent SDK dependency. Signed/provider-shaped values stay unmodified and subject
to the SDK 2.0.0 representation supported by the existing dependency constraint.
This is not general preservation of every SDK field (for example server-tool
raw_content), nor a promise of compatibility with untested providers.

## Evidence and acceptance

The compatibility regressions are:

- spec/phronomy/llm_adapter/continuation_metadata_spec.rb: actual SDK parsing and
  rendered HTTP for text/signature, streaming, Responses encrypted state and
  provider-shaped OpenRouter reasoning; scope/version rejection and legacy input.
- spec/phronomy/agent/continuation_metadata_spec.rb: real Agent Tool loops,
  subsequent invocation, approval across reconstructed storage/Runtime, Handoff,
  and an independent backend with opaque metadata and no RubyLLM calls.
- spec/phronomy/agent/ruby_llm_materializer_spec.rb: historical model_id reading.

The LM Studio gpt-oss-20b reasoning omission was independently reproduced before
this change. The prior isolated A/B diagnostic returned HTTP 200 in all four
trials. This correction therefore does not claim to explain or fix peg-native
HTTP 400, nor to complete Example 22. Actual model behavior and the entire
application acceptance remain separate verification stages.
