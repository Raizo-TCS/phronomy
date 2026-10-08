# r8 unit 6 migration

Apply core and examples together on the applied unit 5 baseline. There are no
compatibility aliases. Update custom adapters and code rescuing LLM failures.

| Previous API | Current API |
| --- | --- |
| `Phronomy::TokenUsage` | `Phronomy::LLMAdapter::TokenUsage` |
| `Phronomy::TransportError` | `Phronomy::LLMAdapter::TransportError` |
| `Phronomy::RateLimitError` | `Phronomy::LLMAdapter::RateLimitError` |
| `Phronomy::AuthenticationError` | `Phronomy::LLMAdapter::AuthenticationError` |
| `Phronomy::ContextLengthError` | `Phronomy::LLMAdapter::ContextLengthError` |
| Adapter `build_chat`, `configure_chat`, `message`, `tool_call` | Backend-owned private translation; removed from the extension SPI |
| Adapter `complete(chat, message, config:)` / `stream(...)` | Inherited `complete(request, cancellation_token:)` / `stream(...)` |
| SDK-shaped recovery provider result | `LLMAdapter::Response` or `Response#to_h` |

Implement protected hooks, leaving public validation/cancellation templates intact:

```ruby
class EchoBackend < Phronomy::LLMAdapter::Base
  protected

  def perform_complete(request, cancellation_token:)
    Phronomy::LLMAdapter::Response.new(content: request.message || "continued")
  end

  def perform_stream(request, cancellation_token:)
    result = perform_complete(request, cancellation_token: cancellation_token)
    yield Phronomy::LLMAdapter::StreamChunk.new(content: result.content)
    result
  end
end
Phronomy.configure { |config| config.llm_adapter = EchoBackend.new }
```

Request contains JSON model_config, optional system/new message, immutable
Message history and inert Tool definition Hashes. `identity` and local
`input_budget` have defaults. Backend hooks return Response; stream yields
StreamChunk values. Tool requests are `Tool::CallRequest(id:, name:, arguments:,
metadata:)` values in an ordered array, with unique nonempty IDs. They never
contain executable Tools or approval decisions. Return assistant responses only.
Response/Message content is text, structured JSON or nil. Unknown token counts
are nil; explicit zero is zero. TokenUsage no longer provides SDK `from_tokens`.

Model/provider are nonempty Strings or nil, temperature a finite number or nil,
max_output_tokens a positive Integer or nil, and instruction-cache/model-existence
flags booleans or nil. The default RubyLLM backend still owns provider-specific
options and error translation. Existing provider/application errors are not
silently swallowed or converted into success. Custom synchronous hooks must
check cancellation during their own long operations where they can cooperate.

## Tool schemas and approval

Tool::Base owns `parameter`/`param`, `parameters`/`params`, declaration inheritance,
name/description, provider options, `validate_arguments`, `call`, and `call_async`.
It is not a RubyLLM::Tool. Incidental inherited SDK APIs such as approval_resolver,
split_result and SDK result/content classes are not part of the new Tool API.
Keep Agent approval policies on the Agent/Tool authorization contract.

`parameters` accepts an explicit object schema or Schematist DSL (the DSL retains
its syntax without loading RubyLLM). JSON Schema 2020-12 is the supported dialect,
implicit when `$schema` is absent. Root type must be object. Supported constraints
include required/extra properties, nested objects/arrays, enum/const, numbers,
strings/formats and combinators. Unknown keywords/formats, alternate dialects,
custom vocabularies, `$id`/anchors and external refs fail at declaration time.
Local `#` / `#/...` references are resolved at construction. `strict` is a provider
annotation, not a substitute for required/additionalProperties constraints.
Defaults are annotations and are not injected into arguments.

Legacy optional `param` declarations continue to accept explicit nil and now
advertise a nullable type (and nullable enum). A legacy optional nil is normalized
to omission before approval/execution, preserving Ruby keyword defaults. An
absent optional key is not injected. Explicit schemas accept null only when their own constraints allow it.

Every declaration path validates before execution. `:raise` raises ToolError;
`:return_error` returns the existing schema-error text; `:coerce` converts explicit
primitive property/item types and then validates every constraint. It does not
guess a branch or cast through references/combinators. Fractional values are not
truncated to integers. Validation snapshots input containers; it does not mutate
the caller's arguments. Top-level keys become keyword symbols. Extra keys with
no declared/inferred parameters are rejected rather than passed to execute.

Approval receives the validated/coerced snapshot. Execution reuses those values
and validates against the same published schema. `on_error` does not turn schema
errors into successful execution. Unqualified legacy array declarations now
advertise unconstrained JSON items, matching their actual validation rule; use
an explicit items schema to restrict them.

## Stored and in-flight executions

Storage SPI and SQL schemas are unchanged. New Tool batch metadata additionally
records `validated_arguments`, separately from the unchanged raw request fields.
Agent authorization projects and compares that exact snapshot (including explicit
null in explicit schemas). Older snapshots without this field use the historical
raw-argument/optional-nil-omission rule. Existing journal message boundaries,
Tool call identities and recorded usage remain readable. Legacy top-level
thought_signature is decoded into opaque CallRequest metadata and rendered by
the backend. Old SDK usage field spellings remain accepted by SavedContextReader.
No stored records are silently rewritten and no automatic migration is run.

Saved Tool definitions are compared exactly. Removing SDK-generated annotations,
correctly advertising nested required/extra-key rules or array item rules can
change the definition even when application source is unchanged. Finish or
explicitly resolve in-flight unit 5 executions on their original version before
upgrading. Quiescent Agent history remains readable. If a saved in-flight Tool
definition differs, recovery rejects it; do not remove that comparison or modify
historical manifests to force continuation. Saved invalid model configuration
also needs resolution on the original version. No new cross-version in-flight
compatibility guarantee is made.
