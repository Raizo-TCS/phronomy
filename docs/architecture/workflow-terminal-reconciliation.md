# Workflow terminal reconciliation

Workflow owns each accepted execution segment until its terminal persistence and
required owner-side application are resolved. A failed observation must not erase
that responsibility. This process-local recovery path uses the captured Workflow
and its original running or draining Runtime; it does not transfer work to a new
Runtime or provide recovery after process loss.

For example, a Workflow can save value `7`, lose the save response, and then fail
its first authoritative read. A later explicit reconciliation can establish that
same saved result without saving again or executing the graph again.

## Retained responsibility and original observation

The Workflow owner retains an immutable description of the attempted save before
submission. Retirement explicitly transfers the original completion obligation
from Engine to Workflow. Persistence classification and owner release remain
Workflow decisions; Engine does not interpret snapshots or business results.

For example, when the first read cannot establish the save outcome, the original
observation fails with `WorkflowTerminalRecoveryError` after custody is retained.
Failing the old source task through normal finalization would release the owner,
so retirement follows its own acknowledged path.

Receiver acceptance and completion delivery are checked separately. The
Workflow operation first accepts the exact retirement envelope. Engine then
detaches the original completion slot and delivers that same envelope through
its source completion. Runner confirms that exact delivery before recovery may
apply and release the owner. Merely returning acceptance or having a different
source task finish is not confirmation. A withheld completion prevents recovery
from applying or releasing responsibility, even if persistence is already known.

The error has code `workflow.terminal_recovery` and exposes
`workflow_instance_id`, `recovery_id`, and `recovery`. `original_error` preserves
the original persistence failure when available; `cause` reports the immediate
operation failure. It is not `CancellationError` or a declaration that the
business result failed. Ordinary and task-bearing Workflows follow this same
observation contract. The original failed TaskResult remains failed permanently.
After a `stream` call returns an error, its old block is not called by recovery.

The capability is read-only, cannot be publicly constructed, and belongs to the
exact compiled Workflow and captured owner. IDs are diagnostic identities rather
than serializable recovery tickets. While unresolved, the registry retains the
obligation even if every caller drops its reference. After resolution, a held
capability preserves its resolved receipt without an indefinite global history
map. It must not be sent as JSON or treated as a cross-process authorization token.

## Explicit observation and lookup

Recovery reads the original repository only while the persistence fact is
unknown. Confirmed persistence, application and release are separate facts.
Concurrent recovery observers share one physical attempt, while cancelling or
timing out an observation does not cancel the retained responsibility.

Each observer receives its own context view even when its physical read is
shared. Mutating one returned view cannot change retained proof or another
observer's context. The application class's construction behavior still applies
to each view, as described below.

For example, after the repository becomes readable, an application can call
`workflow.reconcile_terminal_async(recovery: error.recovery)`. Repeating that
operation after resolution observes the retained receipt rather than loading
storage or acquiring another segment owner.

| Public operation | Contract |
| --- | --- |
| `reconcile_terminal_async(recovery:)` | Returns a fresh `TaskResult<WorkflowTerminalRecoveryResult>`. Invalid or foreign capabilities are rejected before storage I/O. |
| `reconcile_terminal(recovery:)` | Waits for the same operation on a host thread. Blocking on EventLoop is rejected. |
| `pending_terminal_recovery(workflow_instance_id:)` | Reads the captured Workflow's local unresolved index. No storage I/O, Runtime startup or state change. Requires a nonempty String. Returns `nil` when no matching uncertain obligation is indexed. |

The lookup supplies a recovery reference when an initial TaskResult was
cancelled or its error was discarded. It does not report a save still in normal
progress as uncertain. After release, lookup returns `nil`; a capability already
held by the caller still supports repeat observation. This is not a general
lookup across different compiled Workflow instances or process generations.

No retry loop, new save, `resume`, `send_saved_event`, or graph event is part of
reconciliation. Entry, exit, transition, stable-state, task-start, Provider and
Tool callbacks are not replayed. Returned context views are reconstructed with
the declared context class and metadata. A custom constructor or a context field
default can run during construction, so arbitrary context-construction code is
not covered by the graph-callback no-replay guarantee. Construction can fail
independently; another explicit observation can retry that construction using
retained proof, without another read or save.

## Reading the result

Each result captures persistence, application and ownership as an immutable
observation. A subsequent observation may show progress without changing an
earlier result. An application should check the separate states before treating
recovery as finished.

For example, `confirmed_post`, `pending`, and `retained` establish the saved
snapshot but leave owner application unfinished. `confirmed_post` alone does not
permit a new segment or prove that a context view was delivered successfully.

| Reader | Values and meaning |
| --- | --- |
| `outcome` | `confirmed_post`: exact intended snapshot/revision; `confirmed_pre`: original save is proven absent; `unresolved`: readable conflicting evidence; `unavailable`: no classified fact and the read/owner/delivery is unavailable. |
| `application_state` | `pending` or `applied`; whether the exact owner applied the classified disposition. |
| `ownership_state` | `retained` or `released`; release also requires the relevant physical completion boundaries. `pending`/`released` is invalid. |
| `revision`, `context` | Saved revision and an independent context view only for `confirmed_post`. Context may be `nil` when construction fails or the observation cannot materialize a view. |
| `error` | Persistence, read, application or context-construction diagnostic. It does not reverse an already confirmed persistence fact. |
| `recovery`, `workflow_instance_id`, `recovery_id` | The original capability and immutable diagnostic identities. |

Unclassified outcomes are always pending and retained. Confirmed outcomes can
remain pending/retained, become applied/retained, or become applied/released.
Once persistence is known, a later observation retries only missing application
or context construction. Already applied owner steps are not repeated. A result
can be applied/released and still carry a context-construction error; its stored
fact and release are preserved.

Confirmed pre-state follows Workflow's existing known-save-failure policy and
does not replay the save. This differs from an Agent execution whose accepted
durable job may still be active. It is not a shared business-failure rule.

## Application integration

The caller retains observations and local recovery references, decides when an
explicit reconciliation is appropriate, and translates the separate facts into
its own service response. Authorization and any later business retry remain
application decisions.

For example, a service keeps the original TaskResult after a waiter-local
timeout. When its error is available it uses that exact recovery reference; if
the observation was cancelled, it can query the same Workflow's pending index.
Neither path automatically restarts the investigation.

These complete function units require `phronomy` and a configured Workflow passed
as an argument. The shared normal-path behavior is observing its context. The
failure-path change is intentional: a recoverable unknown result now provides a
typed reference instead of leaving an ordinary observation pending indefinitely.

```ruby
require "phronomy"

def observe_workflow(workflow:, input:, workflow_instance_id:, timeout:)
  report = {task: nil, context: nil, error: nil, recovery: nil}
  begin
    report[:task] = workflow.invoke_async(input,
      config: {workflow_instance_id: workflow_instance_id})
    report[:context] = report[:task].wait_result(timeout: timeout)
  rescue Phronomy::WorkflowTerminalRecoveryError => error
    report[:error] = error
    report[:recovery] = error.recovery
  rescue StandardError => error
    report[:error] = error
  end
  report.freeze
end

def inspect_pending_recovery(workflow:, workflow_instance_id:)
  workflow.pending_terminal_recovery(workflow_instance_id: workflow_instance_id)
end

def reconcile_once(workflow:, recovery:, timeout:)
  report = {task: nil, recovery: recovery, observation: nil, error: nil}
  begin
    report[:task] = workflow.reconcile_terminal_async(recovery: recovery)
    report[:observation] = report[:task].wait_result(timeout: timeout)
  rescue StandardError => error
    report[:error] = error
  end
  report.freeze
end
```

The returned report retains its TaskResult on timeout so the caller can observe
it later. A normal return from `reconcile_once` can contain an unresolved or
unavailable observation; application code must not equate it with successful
business completion. An outer operation error and the observation's own `error`
also remain distinct.

## Shutdown and the supported recovery profile

Unresolved terminal responsibility prevents complete cleanup and survives the
original observer's lifetime. The captured Runtime is never silently replaced.
This implementation profile allows recovery while its existing owner can still
receive and apply results; it does not implement a stopped-owner custody transfer.

For example, after the original dispatcher has stopped, lookup still exposes its
retained reference. Reconciliation with no confirmed persistence reports
unavailable; any already confirmed fact remains confirmed while ownership stays
retained. A new default Runtime cannot adopt that old operation merely by using
the same ID.
An already finalized capability can still report its resolved receipt without I/O.

Physical completion is distinct from logical TaskResult settlement. A save that
may still commit cannot be classified as absent merely because one observer
timed out. Neither shutdown nor an unavailable result makes that inference.
Later recovery does not rewrite a previously recorded incomplete shutdown result.
Exclusive host ownership, the repository's monotonic revision/CAS contract and
in-process reference retention remain prerequisites. Pre-state confirmation also
requires authoritative readback ordered after the original save has settled:
that save must not be able to commit later. Local worker or TaskResult physical
completion alone does not establish this remote-storage guarantee, and an
eventually consistent replica is not authoritative readback. The existing
repository capability flags do not certify either condition. A backend that can
commit after returning an ambiguous failure requires separate settlement
evidence or fencing before this profile's `confirmed_pre` result can be relied
on. The in-memory fault tests exercise settled writes; remote adapters require
their own acceptance tests. This implementation does not add that backend
settlement protocol.

Crash durability, remote
request receipts, arbitrary competing writers, stopped-owner takeover and the
remaining Agent recovery paths require separate work.
