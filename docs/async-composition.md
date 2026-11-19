# Result composition and Execution

`Phronomy::TaskResult` represents a pending or settled result. It does not start
a thread. `Phronomy::Execution` starts the input JOBs and waits for the final
TaskResult returned by each JOB. The application defines those completion
conditions and what to do with the collected values.

## Invocation, individual results and fan-in

```ruby
require "phronomy"

def collect_answers_async(agents, question:, invocation_context: nil)
  Phronomy::Execution.run_async(
    agents, timeout: 30, invocation_context: invocation_context
  ) do |agent, execution|
    agent.invoke_async(question, invocation_context: execution.invocation_context)
      .map { |response| response.fetch(:output).strip }
  end
end

# Each outcome identifies the original input position, including failed JOBs.
outcomes = collect_answers_async(agents, question: "Explain the tradeoff").wait_result
outcomes.each do |outcome|
  puts [outcome.index, outcome.status, outcome.value, outcome.error&.message].inspect
end
```

`agents` contains separately generated or loaded Agent instances. Use each
Agent's materialization listener for lifecycle/progress events. Result handling
uses the TaskResult returned by the invocation.

The input must be an Array. Its positions are shallowly copied before any JOB
starts. Start blocks run in input order without waiting for previous returned
results. They can run on the calling thread. Execution adds no per-JOB thread
or worker: keep start and transformation blocks short and use
`Blocking.call_async` for application work that can block. A start block itself
can delay the return of `run_async` if the application performs synchronous work.

Zero, one and many inputs all produce an Array of Outcome records. Empty input
still validates parameters and rejects an already-expired deadline or cancelled
token before completing. `Execution.run` starts the same execution once and
waits for its Outcome Array. The synchronous entrance is rejected on EventLoop
even for empty or already-completed inputs.

## map and flat_map

| Operation | Success callback | Derived result |
| --- | --- | --- |
| `result.map { ... }` | Returns any value | That value, even when the value itself is a TaskResult |
| `result.flat_map { ... }` | Returns a TaskResult | Waits for and adopts that inner result's terminal value/state |
| `result.on_complete { \|value, error\| ... }` | Independent completion notification | Returns the original result; the callback does not transform it |

A callback can run immediately during registration or on the completing thread.
There is no callback thread guarantee. `map`/`flat_map` block StandardError
failures become failures of the derived result, preserving the original error.
A wrong `flat_map` return becomes a TypeError failure. Missing blocks raise
ArgumentError at registration. A source or inner **cancelled state** propagates
as cancelled with the original error. A failed CancellationError, or one raised
by an application transformation, stays failed.

For example, extend each JOB through a second Agent before returning its result:

```ruby
evaluations = Phronomy::Execution.run_async(pairs, timeout: 30) do |pair, execution|
  context = execution.invocation_context
  pair.fetch(:author).invoke_async(question, invocation_context: context)
    .flat_map do |answer|
      pair.fetch(:reviewer).invoke_async(answer.fetch(:output), invocation_context: context)
        .map { |review| review.fetch(:output) }
    end
end
```

If a JOB raises StandardError or returns something other than a TaskResult,
that JOB becomes failed. Other JOBs continue. Once all final results settle,
the whole execution succeeds with the Outcome Array even if it contains
individual failures or cancellations.

## Outcome records and whole-execution deadlines

`TaskResult::Outcome` has read-only `index`, `status`, `value` and `error` fields.
The returned Array and its records are frozen. Values and original exceptions
are retained by reference, without deep copying or freezing application objects.

| Whole execution | Whole TaskResult | Available records |
| --- | --- | --- |
| All JOBs settled | completed | Successful value is the Outcome Array |
| `timeout:` won | failed, ExecutionTimeoutError | `error.outcomes` |
| Explicit or inherited token/deadline cancellation won | cancelled, ExecutionCancellationError | `error.outcomes` |

Record statuses are `:completed`, `:failed`, `:cancelled`, and, in an interrupted
snapshot, `:unfinished`. Unstarted JOBs also have unfinished records. This is
not another terminal state of TaskResult. A JOB's record refers to its final
returned result, so completed transformed values are retained; an unfinished
inner `flat_map` result makes that JOB unfinished.

The execution serializes record updates and terminal claims. The first terminal
claim wins. At timeout/cancellation it fixes the records before requesting child
cancellation; later notifications cannot rewrite those records. It does not
retroactively decide using physical worker completion timestamps.

`timeout:` covers fan-out start through the final JOB results reaching fan-in.
`nil` adds no deadline. Zero or negative values fail before starting JOBs. It
accepts finite real Numeric values usable as elapsed seconds; other types raise
TypeError, and non-finite/complex values raise ArgumentError. These checks occur
before JOB starts or cancellation subscriptions. The existing Blocking numeric
conversion rules are unchanged.

`cancellation_token:` accepts nil or a CancellationToken (including subclasses).
`invocation_context:` accepts nil or an existing InvocationContext (including
subclasses). Other types raise TypeError at the Execution entrance.

`TaskResult#wait_result(timeout:)` sets only that caller's wait limit. It does not
cancel or alter the underlying result. Pending waits are forbidden on EventLoop.
An individual Blocking timeout keeps its TimeoutError failure; an individual
deadline token keeps the cancellation state. These are distinct from the whole
execution's errors and snapshot.

## Context, cancellation and ownership

Pass `execution.invocation_context` explicitly to an Agent or to
`Blocking.call_async(invocation_context: ..., cancellation_token: ...)` for work
belonging to that execution. The result is bound before it returns to the app;
its `map`/`flat_map` continuations inherit the scope. A continuation checks the
scope before running. Explicitly passing the context again when starting an
inner operation also covers cancellation after the continuation has begun.

An optional existing context contributes its user, policy, budget and tracing
information by reference. Execution derives a new context without modifying
the supplied one. Existing context cancellation/deadline and the explicit
Execution token/timeout all remain effective. Controls connect one way into a
private token. Cancelling one execution or an individual operation does not
cancel a parent's or another caller's shared token. Agent and Blocking admission
combine the individual token with the context's controls.

Scope cancellation stops unstarted scoped operations/transformations and requests
cooperative cancellation of running operations. It does not use Thread#raise,
roll back effects, or guarantee physical worker termination. Offload work and
owned composition steps retain their physical-completion tracking after logical
cancellation. `on_complete` notifications still run, and suppressed framework
continuations settle as cancelled rather than remaining pending.

Execution waits only for registered JOBs' returned final results. If a JOB
starts X and Y but returns Y, the app is responsible for X. Normal completion
does not discover, join, or sweep-cancel X. If the app explicitly supplied this
scope to X, its API's cancellation and closed-scope start restrictions still
apply. A normally closed context cannot be reused to start another operation.

## Observing work started elsewhere

```ruby
# Source started under its original owner and controls.
shared_result = existing_agent.invoke_async(question)

run = Phronomy::Execution.run_async([shared_result], timeout: 5) do |source, execution|
  execution.observe(source).map { |response| response.fetch(:output).upcase }
end
```

`observe` returns a distinct scoped result. It does not restart, rebind or cancel
the source, its existing continuations, or its physical work. A JOB may also
return an external result directly if it only needs to wait for it.

`TaskResult.all_settled(results)` is the public wait-only API. It accepts an Array
of TaskResult instances/subclasses, snapshots the positions, and preserves order
and duplicate positions. Invalid elements cause an immediate TypeError before
any source is subscribed. It accepts an empty list and has no timeout/cancel
parameters. It does not own or infer scopes from its sources. If subsequent
transformations should be scoped, explicitly use
`execution.observe(TaskResult.all_settled(results)).map { ... }`.

## Whole-result processing and existing layers

The whole TaskResult is the scope exit. An outer `map`/`flat_map` does not inherit
or extend the completed inner scope, whether registered before or after fan-in.
For example, vote counting belongs in an outer `map`. A slow save belongs in an
outer `flat_map` returning `Blocking.call_async(timeout: 5) { ... }`. That new
operation's five seconds start when it is invoked, independently of the first
execution's deadline. There is no `compose` argument or separate fan-out entrance.

Execution owns common runtime coordination. Orchestrator remains above the Agent
layer: `dispatch_parallel[_async]` retains Agent construction, knowledge
inheritance, bounded active children and `on_error` policy, and delegates its
runtime coordination to Execution. AgentExecution remains the durable Agent
record; ExecutionCoordinator keeps admission, persistence, approval, recovery
and terminal barriers while reusing the common context/control binding.

## Direct Orchestrator children

Direct dispatch owns children while preparing and invoking them, then transfers
successful children through returned result identifiers. Children whose results
are discarded need a safe release path or an explicit retained-owner error.
Runtime's strong ownership remains necessary for successful Agent reuse.

For example, a successful `subagent` result includes `agent_id`, so the caller
can retrieve that same child and use or unload it. A failed child in
`dispatch_parallel(..., on_error: :skip)` is released before its ordinary failure
becomes `nil`. If `on_error: :raise` discards the entire result array, successful
siblings are also released because their identifiers are not being returned.

Children are materialized when their JOB starts, with construction and inherited
knowledge writes off EventLoop. Queued JOBs that never start do not create Agent
owners. Invocation cleanup follows physical completion; a logical cancellation
does not authorize unloading a still-running child. Stored Agent history is
preserved by unload, and direct calls do not create durable parent executions.
The parent's knowledge snapshot is still read synchronously at dispatch entry;
this does not add default knowledge-inheriting dispatch support on EventLoop.
An EventLoop caller must use `inherit_knowledge: false` under the existing rule.

A timeout or explicit whole-execution cancellation also does not return a normal
result array. Completed child payloads in the execution error remain useful
history, but do not promise live child owners after release.

Direct helpers retain their child return-or-release obligation until it settles.
For example, an unanswered child approval at the finite shutdown deadline leaves
cleanup incomplete and retains the Runtime. It is not the ordinary standalone
Agent saved-wait shutdown path, and it does not imply hosted parent/child detach
support. No answer or forced release is invented to make shutdown complete.

Safe-release failures discovered before observed completion raise
`Orchestrator::ChildCleanupError`, even with
`on_error: :skip`. Its `failures` array contains `{agent:, error:}` records for
exact retained owners; `primary_error` and `result` preserve the available
operation failure and result. A result payload is not a promise that its Agent
remains loaded; the `failures` records identify the owners still requiring care.
Resolve approval or recovery requirements before
retrying the failed owner's `unload_async`. Retrying release does not repeat the
child's business operation. The caller must not treat this error as an ordinary
discarded child failure.

If timeout or cancellation has already settled the outer result while a child
is still running, later cleanup cannot replace that earlier result. A late
release failure retains the owner and reports its `agent_id` and cause through
the configured logger, or a warning when no logger is configured. Applications
needing direct access to every child throughout cancellation should create and
own Agents explicitly, then compose their results with Execution.

Cancelling an observation handle alone is not a durable transfer of ownership.
Retain and observe the operation, or use its explicit cancellation policy and
inspect completion. No new background cleanup service, generic Registry or
automatic approval is introduced. The hosted durable subagent path keeps its
separate saved parent/child and approval contracts.

## Development-release migration

- Replace `Phronomy::Task` with `Phronomy::TaskResult`. The old constant and file
  are removed; there is no compatibility alias.
- Replace `orchestrator.fan_out(agent: klass, inputs: inputs, ...)` with
  `orchestrator.dispatch_parallel(*inputs.map { |input| {agent: klass, input: input} }, ...)`
  when keeping Orchestrator's Agent construction/knowledge/concurrency policy.
  Use Execution directly for application-defined JOB result composition.
- Replace the asynchronous equivalent with `dispatch_parallel_async` or
  `Execution.run_async` as appropriate. `fan_out` and `fan_out_async` are removed.
- Keep per-incarnation listeners at Agent creation/load. This change introduces
  no invocation listener blocks, Proc persistence, durable result transforms,
  callback acknowledgements or new scheduler.

See examples `32_async_composition` for complete basic and asynchronously
evaluated majority-vote applications, and `23_bounded_parallel` for bounded
Agent dispatch. Examples must depend on a core commit containing these APIs.
