# ADR-011: Delegate Transport Timeout and Retry to Adapters

## Status

Accepted

## Context

Phronomy accumulated execution-policy settings at several layers:

- `Agent::Base.retry_policy`, which replayed the complete Agent invocation;
- `Agent::Base.invoke_timeout`, which imposed an Agent-class deadline;
- `config[:llm_timeout]`, applied outside RubyLLM;
- Tool `retry_on` and `config[:tool_timeout]`;
- `max_parallel_tools` and the unused `InvocationContext#provider_limits`.

The policies did not share a reliable resource model. In particular, replaying
an Agent or Tool can repeat external side effects, and a pool-level timeout does
not terminate a blocking provider call that is already running. RubyLLM already
owns LLM request timeout, transient-error retry, backoff, and jitter. Tool
implementations commonly use clients that own equivalent transport behavior.

## Decision

1. RubyLLM, or another configured LLM adapter, owns LLM transport timeout,
   retry, backoff, jitter, and provider rate-limit handling.
2. Phronomy translates final provider errors but does not replay the complete
   Agent invocation.
3. Tool implementations or their underlying clients own Tool-specific timeout
   and retry. Phronomy does not provide a generic Tool replay policy.
4. Agent classes do not own a default invocation timeout. Callers may pass an
   `InvocationContext` containing a `deadline` or `cancellation_token` when a
   specific root operation needs a boundary.
5. Phronomy retains the timeout mechanisms for boundaries it owns: Workflow
   actions, authorization evaluation, Orchestrator aggregate waits, Runtime
   shutdown/drain, and generic concurrency primitives.
6. Parallel Tool execution is a boolean mode. When enabled, all authorized
   calls in the intercepted batch are dispatched. Runtime's bounded workers and
   queues remain the coarse process-protection mechanism.
7. No resource manager, provider limiter, priority scheduler, or compatibility
   shim is introduced by this change.

## Consequences

### Positive

- LLM transport behavior has one configuration authority.
- Agent and Tool side effects are not implicitly replayed by the framework.
- Timeout behavior is controlled at the layer capable of interrupting or
  cancelling the underlying I/O safely.
- Invocation context remains small and contains only values consumed by the
  execution path.
- The Agent FSM has one invocation attempt and one error propagation path.

### Tradeoffs

- Applications must configure RubyLLM explicitly when its defaults are not
  appropriate for production.
- Custom LLM adapters must document and implement their own transport policy.
- Tool authors are responsible for idempotency when they choose to retry in a
  Tool or client.
- Enabling parallel Tool execution dispatches the complete authorized batch;
  applications should leave it disabled when unbounded batch fan-out is not
  acceptable.

## Example

```ruby
RubyLLM.configure do |config|
  config.request_timeout = 120
  config.max_retries = 3
  config.retry_interval = 0.1
  config.retry_backoff_factor = 2
  config.retry_interval_randomness = 0.5
end

context = Phronomy::InvocationContext.new(
  deadline: Phronomy::Concurrency::Deadline.in(30)
)

result = MyAgent.new.invoke("Hello", invocation_context: context)
```
