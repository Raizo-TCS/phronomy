# RubyLLM transport error boundaries

## Purpose and ownership

Applications need to handle a failed provider communication through Phronomy's
public API without knowing the HTTP client hidden behind the selected backend.
LLM generation and embedding are separate contracts, so each retains its own
existing `TransportError`. The concrete RubyLLM backends translate identifiable
communication failures; Agent, Generation and Execution propagate that result.

This change adds no public class, parameter, failure code, cross-contract edge,
shared error translator or retry mechanism. Faraday references remain in the two
concrete backends. The public RBS shape is unchanged.

## Mapping and exclusions

| Failure at the RubyLLM boundary | LLM complete/stream | Embeddings |
| --- | --- | --- |
| `Faraday::TimeoutError` | `LLMAdapter::TransportError` | `Embeddings::TransportError` |
| `Faraday::ConnectionFailed` | `LLMAdapter::TransportError` | `Embeddings::TransportError` |
| Existing RubyLLM errors | Existing authentication/rate-limit/context/transport classifications | Existing authentication/rate-limit/transport classifications |
| Application streaming callback, including either Faraday class above | Original exception identity | Not applicable |
| Cancellation, execution deadline, arbitrary I/O, programming failure or unrecognized Faraday error | Original exception identity | Original exception identity |

The top-level mapped exception preserves the original message and its SDK/HTTP
exception as `cause`. That exception's network cause is retained, for example:
`LLMAdapter::TransportError -> Faraday::TimeoutError -> Net::ReadTimeout`.
No classification is inferred from an exception's message or nested cause.
Generic `Faraday::Error`, `Faraday::SSLError`, raw `IOError` and system errors are
not added to this mapping. Future additions require evidence and an explicit
category decision rather than a blanket rescue.

The LLM backend's callback identity check runs before provider classification.
An application callback throwing `Faraday::TimeoutError` therefore remains the
same object. A provider timeout after a delivered chunk is a transport failure;
the already delivered chunk is not withdrawn, replayed or turned into success.

## Application code before and after

Before, handling a provider timeout required knowledge of the backend's client:

```ruby
begin
  response = adapter.complete(request)
rescue Phronomy::LLMAdapter::TransportError,
       Faraday::TimeoutError, Faraday::ConnectionFailed => error
  warn "Provider communication failed: #{error.message}"
end
```

After, the same communication categories are handled through the public owner:

```ruby
begin
  response = adapter.complete(request)
rescue Phronomy::LLMAdapter::TransportError => error
  warn "Provider communication failed: #{error.message}"
end
```

Embeddings applications use `Phronomy::Embeddings::TransportError` in the same
way. Applications may inspect `cause` for diagnostics, but ordinary transport
handling does not need a Faraday dependency. Existing specialized errors remain
available for applications that distinguish authentication or rate limiting.

## Retry, interruption and lifetime

The accepted [transport-policy ADR](../decisions/011-delegate-transport-policy-to-adapters.md)
continues to apply. RubyLLM owns its configured HTTP retries. Phronomy translates
the failure reaching its boundary and does not replay the LLM operation, Agent
invocation or Tool work. A transport classification does not assert that no
output or external effect occurred, and does not authorize a retry.

An execution deadline and an HTTP timeout remain different failures. This change
does not force worker threads to stop, alter cancellation, or make an active
Agent safe to unload. Once an ordinary provider failure has settled and its
physical work has finished, the existing lifetime APIs can release its owners.

The minimum Faraday streaming path can still lose HTTP status and cause RubyLLM
to retry a known schema/Tool rejection as a synthetic ServerError. That separate
dependency/protocol issue is not fixed by this exception-classification change.

## Verification

Unit contracts cover both mapped types across complete, stream and embed,
identity exclusions, same-class callback failures and failure after partial
output. Loopback HTTP tests exercise the real RubyLLM/Faraday stack for timeout,
connection loss, partial streaming with SDK retries enabled, callback identity,
and GeneratorVerifier propagation/release. The minimum HTTP CI job runs these
contracts too. Test-only shortened timeouts do not change production settings.

These tests do not certify live model answer quality, schema/Tool combination
support, or the root cause of the earlier unreproduced LM Studio wait.
