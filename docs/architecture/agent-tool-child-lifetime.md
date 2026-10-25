# Agent Tool child lifetime

`Tools::Agent.from_agent` owns one fresh Agent and ephemeral Store per call.
The Tool releases its private live child after the invocation and its physical
work finish. Ordinary application-owned Agents and durable MultiAgent children
retain their own explicit lifetime and recovery policies.

## Public behavior

`from_agent`, `call`, `call_async` and `execute` keep their arguments. Successful
output remains `result[:output].to_s`, including the empty String for nil. Tool
validation, cancellation-token precedence, error policy, truncation and configured
result-transform order remain in their existing owners.

The synchronous `execute` now waits for the same internal asynchronous operation
used by `call_async`. Both invoke the child's `invoke_async` implementation.
An application override of only `invoke` no longer changes the synchronous Tool
path; there is no legacy dispatch branch. Synchronous EventLoop entry is rejected
before creating a Store or child.

Normal Tool completion includes release. No OffloadPool worker or new Thread is
used merely to wait for the child or its release. The existing Agent release can
perform its ordinary asynchronous persistence checks. Records are not purged,
and unrelated Agents or shared stores are not shut down.

## Cancellation and approval

Logical result settlement does not prove that physical work has ended. The
operation keeps ownership until both source boundaries are complete, then calls
the existing `unload_async`. Cancelling an observation handle does not cancel
this finalization or silently release an active child. Use the accepted
CancellationToken to request operation-wide cancellation.

Pending approval is not terminal. This Tool neither auto-approves nor adds a
child-event forwarding API. A child requiring external approval still needs an
application-defined way to deliver that approval. Active work, other accepted
operations, retention and unresolved recovery continue to prevent release.

When several Agent calls observe the same terminal execution, C04 acknowledges
all of those finished operations before publishing any logical result. Otherwise
the first result callback could request release before a sibling approval waiter
has acknowledged completion. Each OperationResult still waits for its own tracked
physical work. Independent operations and synchronous caller leases remain live;
they are not force-released by this batching.

## Cleanup failure

On successful cleanup, the operation preserves its output or original exception.
Ordinary Tool error policy is applied afterward. A cleanup failure instead raises
`Tools::Agent::CleanupError`, a `ToolError` with code
`tool.agent_cleanup_failed`, even when the Tool suppresses ordinary failures.

| Reader | Meaning |
| --- | --- |
| `child_agent` | The exact child instance whose release failed |
| `agent_id` | That child's identity |
| `result` | The successful String before Tool truncation, or nil |
| `primary_error` | Invocation or conversion failure, when present |
| `cleanup_error` | Release failure |
| `cause` | The primary error when present, otherwise the cleanup error |

The application may retry `error.child_agent.unload_async` when the release
condition has been resolved. This retries release only: it never invokes the
Agent, model or Tool again. The error and live child reference are process-local;
persisted error diagnostics do not reconstruct an owner or retry capability.

Every cleanup failure is also reported with its child identity, stable code and
both available failure diagnostics. This includes failures after an outer
observer has already cancelled its handle. The settled observer is not overwritten.
The owner remains registered for inspection through the existing Agent API.
Diagnostic failures do not replace the operation error or repeat work.

## Responsibility boundaries

| Owner | Responsibility |
| --- | --- |
| I04, concrete Agent Tool | Fresh child acquisition, invocation, output conversion, release request and child-specific failure information |
| C04, Agent | Admission, physical-operation leases, approval, recovery, retention, unload safety and terminal waiter acknowledgment |
| C06, Tool | Input validation, general error policy, truncation and result transformations |
| C13, Execution | Neutral logical/physical completion and asynchronous finalization composition |

The private `AsyncOperation.finalize` captures startup failure, observes a
TaskResult's logical and physical completion, starts one supplied cleanup
operation and observes its completion. The owner supplies error combination.
It is independent of application Execution cancellation and contains no Agent,
Store, Tool or provider policy. A callback-only source is not accepted by this
private finalization API; the start and cleanup functions must return TaskResults.

This does not add a public finally, async scope or one-shot Agent API. The
concrete Tool does not regain a dependency on the application `run_once`
composition, and does not manually settle TaskResults. Agent release decisions
are not moved into Execution or Engine.

## Runtime reference lifetime

Agent entry actions resolve their owner from the invocation being processed.
They do not curry a live Agent into the generated state-machine class. This
prevents VM method caches for generated callbacks from extending Agent lifetime.

FSMSession owns its context between events. The state-machine tracker receives
that context while an event is dispatched, then drops its temporary reference
when dispatch returns, including on errors. Later events rebind the same live
session context. This does not clear the session's context, end pending work,
change approval handling, or relax Agent unload admission.

For example, retaining a completed Tool handle must not retain the child through
either generated callbacks or a completed state-machine transition. Ruby 3.2.3
can retain those execution objects through method caches after the logical
operation ends. Separating their temporary references from session ownership
allows the released child to be collected without changing the Ruby or
state_machines dependency versions.

Completed synchronous `ExecutionChange` objects can also remain reachable from
an idle worker's Fiber/stack, including on the Ubuntu build of Ruby 3.2.3. After
commit and any ambiguous-outcome readback finish, the change drops its live Agent,
write callback and participant references. It keeps its result and descriptive
data. This cleanup runs after success or failure, never before the participant's
commit, evidence collection or recovery guards have finished. A completed change
remains single-use; it does not grant a new opportunity to commit or replay work.

These changes stay inside Agent execution/participation and Engine dispatch
lifetime; they introduce no new Contract dependency or public API. In particular,
OffloadPool does not acquire Agent-specific cleanup policy, replace worker
threads, or create a new Fiber to make collection happen.

## Verification

Offline tests use real Agent operations and a fixed local LLMAdapter. They cover
sync/async success and failure, startup and conversion errors, repeated calls,
single-worker parent Tool dispatch, approval, independent leases, parallel
children, observer and token cancellation, cleanup failure and retry, shutdown,
result transforms and collectability while one or several completed handles
remain live. The original single-child GC assertion is retained unchanged.
Participation tests retain completed changes while checking collection of their
execution-only wiring after success, rollback and lost commit response. The
last case also verifies that readback runs once and returns the committed result.
Neutral completion tests exercise both boundary orders, duplicate/concurrent
notifications, cancellation, startup/cleanup errors and invalid handles.

These tests do not establish real-provider availability or resolve LM Studio's
separate PEG output-parse failure.
