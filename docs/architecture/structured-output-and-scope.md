# Structured Agent output and application lifetimes

This contract supersedes the parser fallback described in the earlier Generation
ownership documents. Agent owns the promise made by `output_schema:`; Generation
owns the draft/review protocol and evaluation; the application owns publication,
authorization and any decision to start another attempt.

## Public behavior

`Agent::Base#invoke`, `invoke_async`, `stream`, `stream_async` and
`start_reserved_async` accept `output_schema: nil` and `schema_delivery: nil`.
`run_once` forwards both options. With a schema, omitted/nil delivery means
`:native`; explicit `:native` and `:none` are supported. A non-nil delivery without
a schema, or any other value, raises ArgumentError before admission. The same
keywords and final-output semantics apply to sync/async and invoke/stream.
Without a schema the existing free-text behavior remains. With a schema, successful
`output` and `result` are deeply frozen JSON objects with String keys; `raw_output`
preserves the model text. Token events are provisional, not validated objects.
The final Task and terminal event are produced only after validation. Output
filters run before validation and cannot silently break the promised shape.

```ruby
schema = {
  type: "object", properties: {answer: {type: "string"}},
  required: ["answer"], additionalProperties: false
}
value = Phronomy::Agent.open_scope do |scope|
  agent = scope.create(AnswerAgent)
  agent.invoke_async("Explain the result", output_schema: schema)
end
puts value.fetch(:output).fetch("answer")
```

C17 `OutputParser::JsonSchemaParser.new(schema:).parse(text)` performs strict JSON
decoding and JSON Schema validation. It does not extract fenced JSON, remove model
control tokens, coerce numbers, clamp scores or repair missing fields. Duplicate
keys, comments, invalid escapes, control characters and nonfinite values fail.
Existing extraction-oriented parsers remain available for their separate purposes;
they do not define Agent's structured-output guarantee.

The supported vocabulary is `$schema`, `$defs`, `$ref`, title, description, type,
enum, const, anyOf, properties, required, additionalProperties, items, minItems,
maxItems, minimum, maximum, exclusiveMinimum, exclusiveMaximum, multipleOf,
minLength, maxLength and pattern. The root must declare type object. Nested nullable
values and local JSON Pointer references are supported; external/cyclic references,
unknown keywords, invalid patterns and invalid schemas are rejected before model
or Tool execution. The dialect is JSON Schema 2020-12. Schema input accepts JSON
values and String/Symbol keys, snapshots recursively, and rejects duplicate normalized
keys, Ruby objects and cycles. Generic schema interpretation belongs to C17, not
Tool::Schema, Agent's caller or Generation.

## Schema delivery and completion facts

`:native` sends the declared schema to the provider. `:none` omits native schema
configuration on every turn, including Tool follow-ups, but retains the same
strict local validation, completion checks, output filters, frozen values and
OutputError reasons. It does not send JSON mode, rewrite prompts, infer behavior
from provider/model names, fall back after rejection or regenerate malformed
output. Applications must already ask for the declared JSON shape in their
instructions. Tools and their authorization rules remain unchanged.

Use `schema_delivery: :none` explicitly where native schema delivery cannot be
combined with the application's Tools. This does not repair LM Studio PEG errors:
a provider failure before a usable response remains a provider failure.

With `:native`, C09 `LLMAdapter::Request#response_schema` carries the immutable schema; each model
turn retains it. RubyLLM `with_schema` sends native schema configuration. The
transport tests cover RubyLLM 2.0.0 OpenAI/Azure Chat Completions and Responses,
Anthropic, Gemini and Ollama's OpenAI-compatible endpoint. Constraints are compared
with the actual HTTP payload. SDK removal of root schema/title annotations does not
change validation. These are offline protocol tests, not certifications of every
remote model. Known model capability failures and native schema rejection raise
`LLMAdapter::StructuredOutputUnsupportedError` (`llm.structured_output_unsupported`).
Unregistered OpenAI-compatible local models may attempt native schema delivery.
Other providers are rejected explicitly for structured requests until their native
transport has been verified. There is no downgrade to JSON mode or prompt-only
instructions. Tool capability is checked too when the model catalog is available;
remote schema/Tool combination rejection remains a provider failure.

LM Studio's HTTP 400 string error `Cannot combine structured output constraints
with lazy grammar` is a known native schema/Tool rejection. It is classified as
`StructuredOutputUnsupportedError` with its original cause, for both complete and
stream operations. Unrelated string errors and requests without a schema retain
their ordinary transport-error behavior. The adapter neither downgrades schemas
nor replays requests. RubyLLM's configured transport retry policy is independent.
The minimum Faraday streaming callback omits the HTTP status, so RubyLLM may
surface this same exact rejection as `ServerError`; its cause is preserved too.
That synthetic server status can trigger SDK retries before the adapter receives
the error. Adapter replay tests disable SDK retries to verify their own boundary.

`Response` records finish_reason (stop, tool_calls, length, content_filter, refusal,
unknown), refusal and raw_finish_reason metadata. Only normal final completion can
be a structured success. Tool requests are intermediate; they retain existing
approval, denial, cancellation and recovery behavior. RubyLLM 2.0 loses streamed
refusal fields in Chunk values; operation-local Protocol subclasses capture these
raw facts on every stream, independently of native schema delivery. No SDK global class or shared protocol registry is patched. The SDK's
raw finish information is retained through saved-response recovery.

JSON 2.21.2 is the verified minimum for the strict decoding flags and deterministic
schema serialization; the minimum dependency CI pins JSON 2.21.2 and RubyLLM 2.0.0
alongside the existing minimum HTTP dependencies. Unknown SDK or parser faults
remain failures, not poor-quality Generation results.

## Failure and persistence

`Agent::OutputError < Phronomy::Error` exposes execution_id, schema_digest, reason,
violations and raw_output. Violations contain pointers/keywords without embedding
model text. Raw text is explicitly available for controlled diagnostics; generic
error messages do not interpolate it.

| Code | Reasons |
| --- | --- |
| agent.output_invalid | invalid_json, schema_mismatch, missing_output |
| agent.output_refused | model_refusal |
| agent.output_incomplete | length, content_filter, unknown_finish_reason |

Agent owns error translation. Parser invalid_json/schema_mismatch become OutputError
with the original cause. A saved error is restored by its explicit owner codec;
no arbitrary class name is constantized. Other transport, cancellation, Tool and
internal failures keep their existing behavior. Output failure never triggers an
automatic regeneration or replay of a completed Tool operation.

New structured executions store `output_contract` version 2, schema_ref,
schema_digest and schema_delivery (`"native"` or `"none"`) at admission. Digest is SHA-256 of UTF-8 JSON generated with recursively sorted keys
(JSON 2.21.2 `sort_keys: true`); the exact same representation is saved in ContentStore.
This format preserves arbitrary JSON integers and finite floats, including -0.0,
without applying the narrower Common canonical-domain number rules. Each Context
Manifest carries response_schema_ref only for native delivery. The output
contract always keeps schema_ref, including with `:none`, so local validation
survives recovery. The digest identifies the schema alone; exact execution identity
also compares delivery. Resume/approval restore the saved choice, and a reserved
ID cannot be reused with a different schema or delivery. Generic config/provider
schema overrides are rejected.

Structured success stores JSON result plus raw_output_ref and result_format=json.
Old records without output_contract remain facts from a free-text execution; no
schema is added retroactively. Existing output_contract version 1 is read as
native delivery and is not rewritten merely by reading. Version-2 contracts use
AgentExecution envelope 0.3; old/freeform executions retain envelope 0.2. New
readers accept both explicitly. Older readers reject envelope 0.3, including for
completed executions, instead of silently losing delivery policy. Deploy compatible
readers before writing new structured executions; do not downgrade a store that
contains 0.3 records to older readers. Unknown versions and digest mismatch fail
closed. Saved LLM responses include finish_reason,
refusal and metadata; missing finish evidence is unknown, never assumed normal.
Fresh-runtime and new SQL connection-pool tests verify success, failure and approval
continuation without replay of confirmed LLM/Tool work. This is a durable-facts
claim, not an external side-effect exactly-once guarantee.

## Generation evaluation

`GeneratorVerifier.new` and `.open` accept `schema_delivery: :native` (default) or
`:none`. One choice applies to both draft and review operations. Their independent
schemas and C03 evaluation policy remain unchanged; no role-specific flags or
automatic fallback are introduced.

C03 specifies the fixed protocol: draft answer/string, confidence/number in 0..1,
citations/array; review approved/boolean, score/number in 0..1, feedback/string.
All outer fields are required and additional properties are forbidden. Default
citation objects require source and excerpt strings. `citation_schema:` customizes
the citation object only; local references are rebased when embedded, without
rewriting const/enum data. Generic validation remains with Agent/C17.

The old draft_parser/review_parser arguments, DefaultParser, ParseError fallback,
score clamping and Generation parser composition wiring are removed. C03 receives
validated String-key values and performs domain evaluation only. Invalid output
returns `Result` with termination_reason=output_failed, interrupted_phase, failure,
confidence=nil and review_approved=nil. Failed draft clears any previous answer;
failed review retains the current valid draft. iterations counts successful drafts.
A valid score of zero can still satisfy a zero threshold; invalid data cannot.
Normal low-quality output follows the configured evaluation loop as before.

`Result#failure` is nil except for output_failed, where it carries the owned error
diagnostic (without raw_output). Hash/JSON round trips, equality, hashing and freeze
include it. `Result.from_h` requires every new field; migrate old saved Result JSON
explicitly with `scripts/migrate_generator_verifier_result.rb OLD.json NEW.json`.
The script adds failure=nil, validates the result and creates a new file. It does
not overwrite the source or silently alter invalid data. `raise_if_unaccepted`
retains the Result and the original OutputError cause in the same process.

## Symmetric lifetime rules

`Agent.open_scope` and `GeneratorVerifier.open` wait exactly once when the direct
block return is a TaskResult. They then attempt all releases. Other values, arrays
and nested Tasks are not recursively awaited. Failure/cancellation is re-raised
with the same identity if cleanup succeeds. Double failure retains primary_error,
all cleanup failures, the scope/pipeline recovery handle and the primary cause.
`result` contains only a resolved successful value, never a failed Task.

`Scope#release!` and GeneratorVerifier release retain failed owners for retry and
remove successful ones. Return true on complete release, false after release.
Partial release rejects new work/acquisition. Concurrent Scope release raises
agent.scope_busy; interruption of a releasing call leaves a retryable failed state.
Materialization receipts are drained to physical completion before release.
Neither API implicitly cancels work, answers approval, deletes saved data or
closes the application Store. The application decides how unfinished work becomes
safe before retrying through the cleanup error's scope/pipeline handle.

## Dependencies and implementation units

- Remove C03 Generation → C17 OutputParser; C03 continues to use public C04 Agent,
  C02 Workflow and C13 Execution contracts.
- Add C04 Agent → C17 OutputParser as a default implementation composed at boot.
  C04 owns the output promise and error; C17 owns syntax/schema interpretation.
- C09 transports schema/final-response facts and remains independent of C17/C03.
- No new Storage, Engine or Runtime-private dependency from Generation is added.

The Contract concept/foundation SVGs reflect these two edges. Generation → Agent
must retain its existing route above OutputParser. Repository source diagrams are
regenerated by the Architecture tool; conceptual target diagrams remain distinct
from the complete source graph.
