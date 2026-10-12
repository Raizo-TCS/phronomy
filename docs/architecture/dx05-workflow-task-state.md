# DX05-D: Workflow-owned asynchronous task states

Status: unreleased Beta implementation. Based on DX05-A core `c673c958c`.

## Problem and intended application boundary

A Workflow application describes which operation a stage starts, how its result
changes business state, and where that state goes next. Repeating callbacks,
completion events, error envelopes and state-entry identifiers obscures those
choices. Workflow already owns the live execution and state-entry lifetime, so it
can own this correlation without knowing how an Agent, Tool or LLM runs.

The business flow is preserved. Failure, cancellation, stale-result and delivery
semantics become explicit and stronger; this is not a claim that every failure
path of the previous manual recipe was equivalent.

## Before and after

Previously, each state manually arranged delivery (simplified successful path):

```ruby
workflow = nil
workflow = Phronomy::Workflow.define(AnswerState) do
  initial :asking
  state :asking
  entry :asking, ->(state) {
    id = state.workflow_instance_id
    agent.invoke_async(state.question).on_complete do |value, error|
      workflow.signal(workflow_instance_id: id, event: :answer_ready,
        payload: {value: value, error: error})
    end
    state
  }
  transition from: :asking, on: :answer_ready, to: :__finish__,
    action: ->(state, event) {
      raise event.payload[:error] if event.payload[:error]
      state.merge(answer: event.payload.fetch(:value).fetch(:output))
    }
end
```

That snippet also needs rejection handling and entry-specific guards for safe
reentry. The application now writes only the operation and successful update:

```ruby
workflow = Phronomy::Workflow.define(AnswerState) do
  initial :asking
  task_state :asking,
    start: ->(state) { agent.invoke_async(state.question) },
    apply: ->(state, result) { state.merge(answer: result.fetch(:output)) }
  transition from: :asking, to: :__finish__
end
```

`start` receives an isolated context snapshot, including current phase and
Workflow identity. It must return a `Phronomy::TaskResult` promptly. It must not
perform blocking I/O or wait for another Task. Use `Blocking.call_async` for real
blocking work. `apply` receives the current context and successful value, runs
briefly on EventLoop, and returns the same context type or nil. Normal transition
guards run after `apply`. Nil means no context replacement, not failure.

A task state may have ordinary entry/exit actions and external transitions.
Leaving it abandons observation of its source. Declaring the same state as both
`state`/`wait_state` and `task_state` is rejected. Ordinary entry/transition actions
still cannot return a TaskResult. Business signals keep their existing API.

## Contract ownership

| Owner | Responsibility |
|---|---|
| C02 Workflow | Task-state definition; live execution and state-entry reception; once-only consumption; success application, failure/cancellation classification; stale-result and queued-progression rejection; restart policy |
| C13 Execution | Thread-safe TaskResult notification and cancellation subscription mechanisms |
| I07 Workflow runtime binding | Connect C02 decisions to the existing FSM, owner EventLoop and owner Runtime timer/shutdown services |
| Engine | Generic event/session delivery and lifecycle; no task-state or Agent policy is added |
| C04 Agent and application | Agent execution, business transformation/fallback, child cancellation policy and producer lifetime |

C02 uses its execution-environment port and receives an injected session
connection. It does not select Runtime or depend on I07. `WorkflowTaskSession`
in I07 adapts the generic FSMSession. Engine source is unchanged.

A revocable C02 reception is created before `start`. Source callbacks retain only
that reception. Closing it drops source and registry references. Completion is
sent to the originating registry under an opaque execution owner token, never
rerouted by a durable Workflow ID. Receiver-side validation checks the current
entry and consumes once. Exits, reentry, cancellation and terminal decisions
revoke it. Queued automatic progression also carries an entry-specific key:
an external transition between result application and automatic dispatch cannot
advance a later entry. These private messages are not public business signals.

## Outcomes and lifetime

| Condition | Caller-visible result |
|---|---|
| Start throws, source fails, or apply throws | Workflow fails with the same error object |
| Source status is `cancelled` | Workflow TaskResult is cancelled with the source error |
| Source status is `failed` with a CancellationError | Remains failed; class alone does not imply cancellation |
| Explicit parent token cancellation/deadline | Cancel Workflow observation; do not implicitly cancel the source |
| Old or duplicated source notification | Ignore; no application or retry |
| Current completion delivery rejects/throws | Fail on the owner; if owner delivery is wholly unavailable, settle observation only and retain admission until shutdown cleanup |
| Runtime shutdown while waiting | Settle observation and revoke subscriptions; no claim that child work physically stopped |
| Known durable terminal result | Use existing save/readback classification and release rules |
| Unknown durable terminal result | Fail the observation while retaining recovery-required ownership |

Cancellation is serialized on the owning EventLoop. Once terminal persistence
has begun, its existing durable barrier remains authoritative; later cancellation
does not reverse a committed or uncertain terminal decision. A source passed to
the state has an independent lifetime. Applications explicitly pass cancellation
controls to children when desired; they own Agent release and side effects.

This API creates no thread/worker for logical waits. Actual I/O and existing
tracing or checkpoint work may still use the bounded pool. Expected business
failures may be transformed into ordinary values through TaskResult composition.
The API does not infer retry, fallback, durable child execution or delivery ACKs.

## Persistence and restart

Normal completion and ordinary `wait_state` halts use existing Workflow
checkpoints. Resuming an ordinary wait into a new task state is supported. Pending
TaskResults, callbacks and entry keys are process-local and are never serialized.
Restoring a snapshot whose phase is a task state raises
`Phronomy::WorkflowTaskResumeError` (C02, subclass of `Phronomy::Error`, code
`workflow.task_resume_unsupported`) before running its start callback. The
application must reconcile that operation explicitly instead of automatically
repeating external side effects. F01 durable child execution remains separate.

## Verification

The new task-state regression suite covers immediate and delayed results,
repeated entry, old success/failure/cancellation, duplicate callbacks, external
transition races, rejected guards, delivery failure, shutdown, source/parent
cancellation, owner Runtime selection, retained-reference revocation, strict
callback result types, normal durable halt/resume, restart rejection and unknown
durable outcomes. Existing Workflow, TaskResult, API and executable-documentation
tests remain active. Examples 01/03/04/07/14/20/25/26 use the new API.
