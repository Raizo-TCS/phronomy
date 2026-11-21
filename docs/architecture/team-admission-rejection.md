# Team admission rejection

Team owns whether an accepted coordination run can continue. Agent owns whether
a particular child-start request was rejected before durable admission. A
confirmed rejection must reach Team without making storage failures or uncertain
execution outcomes look like completed failures.

For example, an earlier release could save a String as Team `durable_context`.
The child requires a canonical JSON-compatible Hash and rejects that request.
Team now records its own failure and becomes available for the next request,
instead of requiring the application to cancel and resume an unstartable run.

## Input acceptance

Team validates the durable input it owns before creating its execution. The
accepted value is a JSON snapshot, so later caller mutation cannot change the
input used by reserved children.

For example, `team.invoke("plan", config: {durable_context: "invalid"})` raises
`ArgumentError` without creating a TeamExecution. A valid Hash remains the saved
input used after restart. `stream` has the same acceptance rule. Passing a new
context to `resume` does not replace an already saved context.

## Reserved-start rejection

Agent reports positively identified validation failures separately from errors
that require recovery or observation. The rejection belongs to a particular
start request; it is not a durable execution outcome or a global absence claim.

For example, invalid durable context in a reserved start raises
`Agent::ExecutionRejectedError`. Its `agent_id` and `execution_id` identify the
reservation, its code is `agent.execution_rejected`, and its Ruby `cause` retains
the validation error. Another caller might already have started that reservation.

The marker covers durable-context snapshot validation, input extraction and
initial preparation metadata validation before admission is attempted. It does
not classify every `ArgumentError`, `ConfigurationError` or internal
`:not_established` result as a confirmed rejection. Persistence reads, admission
participants, commit responses, busy states, Runtime submission and recovery
wiring keep their existing error behavior. A saved failed child still returns
the ordinary exact-execution result with its saved status and diagnostic.

| Entry point | Rejected start | Saved child failure |
| --- | --- | --- |
| `start_reserved_async` | Task fails with the marker for the validation cases above | Task returns the saved result |
| Ordinary `invoke` / `stream` and their async forms | Original error contract | Original failure exception contract |
| `resume_async` / `resume` | No new start is accepted | Return the saved result |
| `start_hosted` | Original error contract | Existing hosted observation contract |

## Team completion

Team combines the child's rejection fact with a guarded observation before
deciding its own final outcome. The Team admission guard serializes that decision
with other processes attempting to accept the same reserved child.

For example, if a worker rejects its initial preparation metadata, Team confirms
the matching reservation has no execution, then saves TeamExecution `failed`
and TeamRoot `idle` in one transaction. The reserved child identity remains in
the Team record, but no fictional failed child execution is created.

The coordinator and worker start paths use the same rule. A rejected start is a
coordination configuration failure even with `on_error: :skip`; that policy
continues to apply to outcomes of children that actually executed. The first
call and later `resume` raise the saved Team diagnostic through the existing
terminal-result contract. The original cause is retained in that diagnostic.

If the reserved child already exists, Team retains its unfinished run and reports
that recovery is required. A later resume observes the actual child. An unknown
observation or commit result also remains recoverable; it is never replaced with
a guessed failed or cancelled result. If a lost terminal commit response can be
confirmed by readback, the saved terminal result remains authoritative.

An application stream-consumer exception still leaves the accepted run available
for resume. It is an observation failure, not a child-start rejection.

## Responsibility boundaries

The change uses the existing Agent result boundary and shared persistence scope.
Agent classifies its request; Team applies coordination policy; Persistence
provides the transaction and guards. Execution and Engine do not choose Team
failure policy.

For example, Team calls the public `Agent::Store#observe_execution` inside the
same scope used for its terminal write. It does not inspect Agent journals or
change the child's execution record. The existing Contract edges `C01 -> C04`
and `C01 -> C07` remain sufficient; no reverse edge or new delegation layer is
required.

The Team guard is acquired before reading the Team execution. Reserved child
admission already takes the same guard before accepting the child. Neither path
waits for Agent execution or provider I/O while holding that guard.
