# LM Studio provider output failures

## Scope and ownership

`Phronomy::LLMAdapter::LMStudio` is an explicitly selected concrete RubyLLM
backend. It handles rejection of the provider's generated conversation format.
It does not parse or repair partial model output, change prompts or sampling
parameters, split Tool/schema requests, or replay Agent/Workflow/Tool work.
The default `RubyLLM` backend and SDK global configuration remain unchanged.

C09 owns the meaning of the public `TransportError` reason code
`llm.provider_output_parse_failed`. A code does not itself authorize retry.
The concrete backend owns HTTP-body decoding and its transport policy under
ADR-011/066. Application composition selects that backend and its retry limit.
No new Contract or Contract dependency is required.

## Recognition and evidence limits

Recognition requires a RubyLLM BadRequestError/ServerError with its own HTTP
response and actual HTTP status 400 or 500. The JSON body must contain `error`
with the exact engine code 500, type `server_error`, and message:

    The model produced output that does not match the expected peg-native format

The engine object may be direct, or JSON after the exact LM Studio prefix
`Engine protocol predict stream returned an error: `, carried in an error string
or the error object's message field. No search through arbitrary strings or
nested exception causes is performed. A malformed/unknown envelope, missing
response or different status/type/code/message remains an ordinary SDK failure.
The original SDK exception remains `cause`; the original HTTP status and body
are not rewritten. The engine's internal 500 is not treated as HTTP 500.

The engine/SDK text was recorded for the earlier gpt-oss failure, but its raw
failed HTTP response was not saved. The HTTP fixture envelopes are **synthetic**,
not a reconstruction of that missing response. These tests establish behavior
for the explicitly supported envelopes; live envelope recognition remains to be
confirmed when a failure is captured. Unknown formats fail closed without retry.
Neither the PEG root cause nor recurrence resolution is claimed.

## Retry policy and configuration

```ruby
context = RubyLLM.context do |config|
  config.openai_api_base = "http://127.0.0.1:1234/v1"
  config.openai_api_key = "lm-studio"
  config.openai_protocol = :chat_completions
  config.request_timeout = 120
end

Phronomy.configure do |config|
  config.llm_adapter = Phronomy::LLMAdapter::LMStudio.new(
    context: context,
    max_parse_retries: 1 # default 0; only 0 or 1 is accepted
  )
end
```

The selected backend snapshots the RubyLLM 2.0 context and disables SDK retries
within that snapshot. **Ordinary 429/500/network retries are also disabled for
this backend.** Applications needing the existing SDK transport policy should
keep the default RubyLLM backend; this selection is deliberately explicit.
The caller's context and global settings are not modified. The frozen snapshot
prevents later scalar context changes from increasing the retry budget.

Only a recognized parse failure can trigger the optional second attempt. It is
limited to non-streaming `complete`, provider `openai`, model
`openai/gpt-oss-20b`, no advertised Tools, no response schema, and no Tool messages
or pending Tool calls in the supplied history. The same immutable request is
used to construct a fresh operation-local SDK chat. Total generation POSTs are
at most two. The one-additional-attempt limit is a conservative policy choice,
not an empirically established optimum or a reliability guarantee.

Streaming is never replayed. Delivered chunks and application callback exception
identity are preserved. Cancellation is checked before another attempt; existing
worker lifetime and deadline behavior remain unchanged. A final failure exposes
the final SDK exception as cause. No successful result is synthesized from an
error body.

## Observation

The existing logical `llm.call` span covers the complete adapter operation.
There is no new trace identity or dependency from C09 to C15. Individual SDK HTTP
requests continue to use RubyLLM's instrumentation. Every failed adapter attempt
also emits a safe warning containing attempt number, reason code, actual HTTP
status when known, and whether a retry was selected; no prompt, raw body or
credential is included. Therefore a later success does not erase the first
failure from the diagnostic record.

An optional concrete-backend `on_attempt:` callable receives these safe fields
plus `outcome`. It must support concurrent calls if an adapter is shared and is
not a durable audit store. Logging/callback failures cannot replace the business
result or original exception. Applications can use SDK instrumentation when they
need request correlation or detailed HTTP evidence. Successful response events
do not invent an HTTP status that the public response does not expose.

## Verification

Offline contracts use a real loopback TCP HTTP server and the actual
RubyLLM/Faraday stack. They verify status/cause fidelity, default no retry, exactly
two POSTs for opt-in recovery/exhaustion, unchanged request JSON, excluded
requests, cancellation between attempts, callback identity, unknown responses,
configuration isolation and unchanged default-backend SDK retries. They do not
invoke a live model.
