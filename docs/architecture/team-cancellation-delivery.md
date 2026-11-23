# Team cancellation delivery

Team owns delivery of an explicit cancellation request to the exact run it is
currently coordinating. The caller's token expresses intent; a confirmed Team
record authorizes signalling the internal token shared by its children. A
notification, a saved cancellation request and a child's physical stop are
different facts.

For example, a research service cancels a Team while a worker awaits an LLM.
The Team's host thread wakes, records cancellation under the existing Team
guard, then signals that child's token. A full ordinary worker queue cannot
discard this request because the cancellation bridge submits no additional
worker job.

## Delivery and ownership

A synchronous Team call retains a run-local control request before registering
its external token callback. The callback only records intent and wakes the
host; persistence and business transitions remain on the Team's host thread.
The same host responds to child completion and cancellation without settling
or cancelling the child's result handle.

For example, registering a token that is already explicitly cancelled can call
the callback immediately. The request and its Runtime admission already exist,
so the host can confirm cancellation before starting a reserved absent child.

- Retain at most the applicable outstanding request for this Team owner.
- Deliver pending intent at control checkpoints before further child work or
  aggregation, and while waiting for a child.
- Use the existing guarded, idempotent cancellation update and readback rules.
- Signal the run's internal token only after confirming the stored intent or
  the authoritative terminal disposition.
- Preserve a confirmed terminal business outcome when cancellation arrives
  too late to change it.
- Close each external subscription using its registration identity; an older
  callback cannot become valid when the same run is resumed.

This is cooperative control of a synchronous Team call. It does not preempt a
blocked persistence operation, scheduler, aggregator or application callback.
Those operations must return before the host reaches its next checkpoint.
Deadline expiry alone is not promoted to explicit cancellation.

## Delivery failure and exact retry

An unconfirmed cancellation write is an operation failure, not proof of a
cancelled or failed Team. Team preserves the local intent, original child
controls and relevant observations so a caller can retry the same target. The
failure carries the Team and run identities even when `invoke` allocated the
run ID internally.

For example, a storage outage can prevent both the cancel write and readback.
The call raises `MultiAgent::TeamCancellationDeliveryError`; after storage
recovers, `team.resume(error.team_execution_id)` retries the pending intent
before advancing that run. A new `invoke` is not recovery for the old run.

| Surface | Contract |
|---|---|
| `TeamCancellationDeliveryError#team_id` | Exact Team owner identity. |
| `TeamCancellationDeliveryError#team_execution_id` | Exact run whose cancellation is still unresolved. |
| `TeamCancellationDeliveryError#code` | `team.cancellation_delivery`. |
| `TeamCancellationDeliveryError#cause` | Original failure where available; preserve it for diagnosis. |
| `resume(id, config: ...)` | Under ordinary Runtime admission, retry retained intent for the same run before further coordination. |
| `cancel(id)` | Explicitly retry the guarded cancellation; discharge retained intent after confirmation, before the optional result query. |
| `result(id)` | Read the saved business state; it is not a local delivery-status query and initiates no retry. |
| `token.cancel!` | Existing notification API; its return is not a durable receipt or physical-stop acknowledgment. |

The new error inherits from `Phronomy::Error`, not `CancellationError`.
Control-delivery failure must not enter the rescue path that commits a Team's
business cancellation. A later result-query failure cannot undo confirmed
cancellation. No automatic storage retry loop is added beyond the existing
guarded-update/readback behavior; an unresolved return requires explicit host
action.

Fatal or control-flow exceptions outside `StandardError`, such as `Interrupt`,
still propagate unchanged. Pending intent remains retained in that case.

## Complete application comparison

Applications retain business and operation outcomes separately and choose when
to retry. The following complete functions use the same host-supplied Team,
input and cancellation token. They run on a thread where synchronous Team
operations are permitted. Team construction, authentication and the decision
to cancel are supplied by the host; neither function starts another run as a
recovery attempt.

For example, an HTTP handler can store the returned run identity with its own
request and offer an explicit retry action after a delivery error. The example
does not automatically replay business work or persist exception objects.

<table>
<thead><tr><th>Baseline API application unit</th><th>Updated application unit</th></tr></thead>
<tbody><tr><td>

```ruby
require "phronomy"

def coordinate(team:, input:, token:)
  report = {
    value: nil,
    operation_error: nil,
    team_id: team.team_id,
    retry_run_id: nil
  }

  begin
    report[:value] = team.invoke(
      input, config: {cancellation_token: token}
    )
  rescue StandardError => error
    report[:operation_error] = error
  end

  report.freeze
end
```

</td><td>

```ruby
require "phronomy"

def coordinate(team:, input:, token:)
  report = {
    value: nil,
    operation_error: nil,
    team_id: team.team_id,
    retry_run_id: nil
  }

  begin
    report[:value] = team.invoke(
      input, config: {cancellation_token: token}
    )
  rescue Phronomy::MultiAgent::TeamCancellationDeliveryError => error
    report[:operation_error] = error
    report[:team_id] = error.team_id
    report[:retry_run_id] = error.team_execution_id
  rescue StandardError => error
    report[:operation_error] = error
  end

  report.freeze
end
```

</td></tr></tbody>
</table>

These are adapted application examples, not repository baseline excerpts.
The call signatures and ordinary result handling are equivalent; failure
behavior intentionally changes. The old bridge could log a rejected submission
and keep waiting without a recoverable control outcome. The new path removes
that submission and exposes unresolved persistence with an exact retry target.
The application still owns retry timing, request authorization, persistence of
its identifiers and handling of business cancellation.

## Runtime lifetime and shutdown

The request belongs to the originating Team and Runtime. An accepted unresolved
intent retains an admission after its original caller returns, preventing
successful Runtime cleanup from silently clearing the Team owner. Confirmed
disposition releases that control obligation; it does not prove that the child
has stopped or that all other Runtime work has been released.

For example, shutdown during a storage outage can report incomplete cleanup
because a pending cancellation is still retained. An application must not
replace the default Runtime and report success merely because the original
Team call has returned an error.

An exact direct `cancel` remains a synchronous persistence/control operation on
the retained current-generation Team. It can confirm the durable fact without
starting another worker, even when new execution admission is closed. It does
not reopen a failed Runtime, make `resume` admissible, or revise a cached
incomplete shutdown result. A Team from a replaced Runtime is rejected before
its control operation writes storage.

The local request is not a crash-durable inbox. Process loss before the
cancellation record is confirmed requires host reconciliation using the exact
identity. Child release still follows Agent ownership, physical completion and
Team terminal-result rules; the control request never authorizes early unload.

## Shared mechanisms and dependency boundaries

This repair reuses the existing result subscriptions, Team guard/readback,
Runtime admission and Agent lifetime contracts. The additional wait and intent
bookkeeping belongs to Team's synchronous host protocol. Its similarity to
Agent or Workflow uncertainty does not establish a shared implementation.

For example, Workflow applies readback on a retained serial owner, whereas this
Team path wakes a blocked host that already owns the synchronous turn. Moving
both behind a new manager would require extra scheduling and policy adapters;
this repair does not establish a net simplification from doing so.

| Concern | Owner |
|---|---|
| Exact run, cancellation record, host checkpoints and retained local intent | C01 MultiAgent / Team |
| Subscription and result-observation primitives | Existing C13 Execution |
| Guarded transaction and neutral persistence rules | Existing C07 Persistence, selected by Team |
| Child execution and unload eligibility | C04 Agent |
| Concrete execution resources and shutdown protocol | Engine through the existing environment binding |

No new Contract, reverse dependency, external library or public Job state
machine is introduced. Existing C01-to-C04/C07/C13 dependencies remain the
architecture boundary. The normative lifecycle specification and fault
scenarios can be shared without forcing one implementation across domains.

| Peer | Symmetry decision |
|---|---|
| Team `invoke`, `stream` and `resume` | Adopt the same retained request and host checkpoints; preserve their existing result/event surfaces. |
| Direct Team `cancel` | Preserve synchronous guarded persistence and signaling. Its caller receives the operation error directly; the host bridge adds exact identities when an external token callback has no return channel. |
| Agent and Workflow | Reuse the same distinction between business facts and observation failures; defer extraction because their serial execution owners differ from Team's synchronous host. |
| Shared delivery manager or separate worker | Withdraw for G1: no second scheduling path is needed to wake the current host, and it would add rejection and shutdown responsibilities. |

## Acceptance and compatibility

Acceptance checks observable effects at the real Team, persistence and Runtime
boundaries. The bounded model explains the selected cooperative protocol and
its environment assumptions; neither syntax checks nor a mock implementation
alone demonstrates that cancellation reaches a real blocked child.

For example, an acceptance case blocks a real provider call, requests external
cancellation while another worker submission would fail, and verifies the
saved cancellation and child signal without creating a delivery job. The
child remains owned until its actual physical work completes.

Required cases include inline cancellation registration, full worker capacity,
write/response loss and readback, unresolved persistence followed by exact
retry, direct-cancel confirmation before result-query failure, terminal races,
stale registration callbacks, original-Runtime ownership and shutdown with
pending intent. Ordinary Team result formats, synchronous APIs, durable record
formats, explicit-token semantics and child-retirement rules remain unchanged.
The identity-bearing delivery error and rejection of new work while an older
intent is unresolved are intentional observable changes.

| Situation | Baseline | Updated behavior |
|---|---|---|
| Ordinary delivery queue is full | Cancellation submission can be rejected and logged. | No delivery submission; the current host wakes. |
| Cancellation write and readback remain unconfirmed | The submitted bridge can fail without returning a recovery identity to the Team caller. | The host reports the exact unresolved run and retains its intent. |
| A new turn is requested with older local intent pending | No retained bridge obligation blocks replacement. | Reject with the older exact run identity; retry that run explicitly. |
| Terminal result or physically unfinished child | Saved result and child retirement have separate meanings. | Preserve both meanings; a late child signal does not rewrite the terminal result. |
