# ADR-004: invoke_timeout Is a Wait Timeout, Not a Cancellation Signal

## Status

Superseded by [ADR-011](011-delegate-transport-policy-to-adapters.md).

## Historical decision

Phronomy previously exposed `Agent::Base.invoke_timeout` as a class-level wait
boundary. The initial implementation did not stop background work; a later
implementation attached a cancellation scope to the complete Agent invocation.

The API has been removed. An Agent class no longer owns a default invocation
timeout. Applications that need a deadline for a particular root operation pass
an `InvocationContext` with `deadline:` or `cancellation_token:`. Those values are
coordination context supplied by the caller, not an implicit Agent execution
policy.

LLM transport timeout belongs to RubyLLM or another configured LLM adapter.
Tool transport timeout belongs to the Tool implementation or its underlying
client. Phronomy retains generic deadline and cancellation primitives for the
execution tree it coordinates.
