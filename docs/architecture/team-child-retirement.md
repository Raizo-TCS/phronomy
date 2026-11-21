# Team child retirement

Team owns the process-local children it creates to execute a coordination run.
Agent owns whether an incarnation is safe to release, while the saved Team and
Agent records retain the durable history. Finishing the Team therefore ends its
need for live child objects without deleting or changing that history.

For example, a server can reuse one Team for many requests. After each run
commits its terminal result and its child operations finish physically, Team
releases the coordinator and worker Agent incarnations. `result` and a later
`resume` still read the saved outcome without running those children again.

## Terminal facts and release eligibility

A confirmed terminal Team result permits retirement of its execution-only
children. An active run or an uncertain persistence result does not establish
that permission. Agent still checks its own accepted operations, execution state
and durable retentions before accepting a release.

For example, a rejected child start can leave a newly created Agent incarnation
without a child Execution. Once Team saves its own failure, that idle incarnation
can be released. Conversely, a worker waiting for approval leaves Team active;
Team retains the live owners and its coordinator class until the answer and
subsequent execution establish a terminal Team result.

The same retirement rule applies to committed success, failure and cancellation.
It also applies when a terminal Team result is confirmed but reading its output
or diagnostic fails. The release does not fabricate a failed child, modify a
saved assignment or convert an uncertain write into a terminal result.

## Logical results and physical work

Team result delivery and process-local retirement have separate completion
boundaries. A caller can receive the saved Team result before child retirement
finishes. Retirement waits for every observed physical operation before asking
Agent to unload; it does not block a worker merely to wait for another worker.

For example, cancelling a child observation can return control while its provider
call is still physically executing. Team can report its committed cancellation
without unloading that Agent early. The existing completion finalizer starts
`unload_async` only after the child observation's physical boundary has finished.
When one worker Agent has several assignments, retirement includes all of its
observations, not only the last logical result.

The implementation composes the existing `AsyncOperation.finalize` and
`TaskResult.all_settled` mechanisms. It does not introduce another lifecycle
registry, scheduler, state machine or recursive child manager. Descendant Agent
Tools remain responsible for their own children under their existing contracts.

During asynchronous release, `Agent::Base.get` can raise `AgentBusyError` because
the incarnation is unloading, and returns `nil` after release succeeds. Team
does not promise that all children are already absent when `invoke`, `stream` or
`resume` returns its logical result.

## Saved identities and live ownership

Team child identifiers describe durable execution history and recovery targets;
they do not transfer ownership of reusable Agent objects to the application.
Team returns task and aggregate values, whereas a direct Orchestrator helper
can deliberately return successful child owners for reuse.

For example, an application can read the worker ID from a saved Team execution
and inspect that worker's stored execution later. It cannot assume that the
process-local worker remains live after the Team finishes. Agent records are
preserved, and the normal explicit Agent loading rules remain available when
appropriate for the application.

The run-specific coordinator class is removed from Team's cache after confirmed
termination. A child whose release fails still retains its exact Ruby class.
Terminal result discovery and retry do not regenerate the coordinator class.

## Failed retirement and retry

A process-local release failure must preserve the already committed Team outcome
and retain the Agent owner. Team reports the Team ID, run ID, Agent ID and cause;
reporting failure itself cannot replace the business result or interrupt another
child's release attempt.

For example, a temporary storage failure can prevent the worker's idle check
after the Team has committed success. The original success remains readable.
Calling `resume` for that terminal Team run retries release of currently loaded
children without replaying the coordinator, worker, scheduler or aggregator.
Calling `result` remains read-only and does not retry cleanup.

Retry uses the saved child IDs with public `Agent::Base.get` and `unload_async`.
It never creates or loads an absent child solely to release it. A live owner
backed by a different Agent Store is rejected and retained rather than unloaded.
There is no background retry loop or new public cleanup error or API.

## Runtime shutdown

Retirement remains bound to the child object and Runtime that owned the work.
It does not look up a replacement incarnation after a delayed physical callback.
Normal Runtime admission and teardown rules continue to govern release attempts.

For example, Runtime draining may reject a new unload request. Team logs that
failure and preserves its saved result and the still-owned child. A successful
whole-Runtime shutdown separately clears process-local ownership; an incomplete
shutdown must not be described as successful retirement. Saved approval waits
do not acquire a new pending-unload obligation merely because Team owns them.

These rules use existing `C01 -> C04` and `C01 -> C13` relationships. Team decides
when its children are no longer needed, Agent decides whether release is safe,
and Execution composes completion without interpreting Team outcomes.
