# Shared retained-attempt management

Agent and Workflow share the management of asynchronous attempts and their
observations. Their domain owners still authorize work, classify persistence,
apply live state and decide when responsibility can end. The shared execution
framework maintains facts that those owners need without selecting their policy.

For example, a report's save response can be lost while its worker continues.
Ending the first caller's observation must not allow a second save or release the
job. Agent and Workflow can use the same attempt and observation machinery even
though Agent retains an accepted job after confirmed noncommit, while Workflow
may end its execution segment with a known save failure.

The implementation baseline is `2d470b6065515f948de8f17f21f810606967bbf6`.
The architecture references are Contract concept v55 and foundation v48, both
reviewed against `9a4cc09c6e1fed2546c142b7a19b94158f71577c`. Those diagrams are
responsibility references, not measurements of this later source. This document
records the shared implementation introduced on 2026-11-28; delivery evidence
identifies the exact tested source and actual validation results.

## Responsibilities and actual consumers

The execution framework manages one retained operation's initial attempt, one
recovery lane and independent observers. Each completion record describes one
attempt's worker result and logical and physical observations. The domain owner
combines those facts with its own authority and state.

For example, approval recovery may restore the same approval wait, while dispatch
recovery may authorize one continuation of a captured invocation. Neither action
is performed by the common attempt manager, even when both reuse its refusal,
worker-result and observer bookkeeping.

| Responsibility | Implementation owner |
| --- | --- |
| Initial attempt, reserved recovery lane, identity, admission facts and observer membership | C13 `RetainedAttempts` |
| Task handle, worker result, logical and physical evidence, notification binding and refresh | C13 `AttemptCompletion` |
| Terminal or saved-wait proof, retry permission, live application and accepted-job release | C04 `Agent::OutcomeRecoveryOperation` and its terminal specialization |
| Approval proof, original wait restoration and continuation transfer | C04 `Agent::ApprovalRecoveryOperation` |
| Dispatch preparation proof, cancellation and once-only continuation permission | C04 `Agent::DispatchRecoveryOperation` |
| Terminal save classification, context reconstruction and execution-segment release | C02 `WorkflowTerminalOperation` |
| Scheduling, worker threads and serial owner delivery | The existing injected execution environment and Engine binding |

`RetainedAttempts` and `AttemptCompletion` live directly in `execution/`, whose
directory is collapsed by the existing loader. Their Ruby constants are
`Phronomy::RetainedAttempts` and `Phronomy::AttemptCompletion`. Both are private
framework implementation. The old `Agent::PhysicalAttempt` class and source path
are removed; no alias points the common layer back into Agent. Public recovery
operations, receipt types and application responsibilities do not change.

Team cancellation continues to retain intent and wake its synchronous host. It
does not acquire an asynchronous worker merely to consume this component.
Native-parent and Handoff connections continue to supply their own exact
authority, routing and persistence proof to the existing Agent owners. Sharing
attempt management does not establish missing adapter applicability.

## Management commands and evidence views

The common manager exposes explicit operations on the recovery lane and returns
read-only views of facts. Owners cannot obtain its mutable slot, completion
record or observer collection through a snapshot. Opaque result and error
payloads retain their existing domain ownership.

For example, an owner first checks whether a persistence retry is allowed, then
reserves the lane for that exact attempt. Later it may retire the lane after its
own completion decision. Retirement removes the lane's bookkeeping; it does not
cancel a worker, settle a TaskResult or release the Agent job.

| Internal operation | Meaning |
| --- | --- |
| `reserve_locked` | Install one explicit recovery identity and its first observer after owner authorization; do not submit work. |
| `join_locked` | Add an observer to the identified attempt; the owner checks compatible operation kind and observability. |
| `snapshot_locked`, `active_snapshot_locked` | Return frozen fact views without completion records or mutable observer arrays. |
| `worker_started_locked`, `submission_rejected_locked`, `task_returned_locked` | Record distinct evidence about an identified submission. |
| `record_worker_locked`, `submission_failed_locked` | Publish worker facts or the owner's supported refusal/uncertainty conclusion. |
| `take_observers_locked`, `retire_locked`, `retire` | Transfer the relevant observers for owner notification and remove the exact lane when the owner permits it. |
| `release_task_locked`, `release_references_locked` | Preserve the owner's existing distinction between dropping only the handle and clearing heavier completion references. |

The methods ending in `_locked` require the existing owner mutex; they do not
acquire it again. This permits a domain guard and its corresponding attempt
change to remain one atomic decision. Other methods acquire that mutex only for
their documented shared-state access. There is no second mutable ledger, new
lock, executor or thread inside either shared class.

## Why these state accesses need synchronization

Owner delivery is serial, but worker facts and observer changes also originate
outside that owner thread. Synchronization protects those actual shared facts
and the compound decisions that consume them. An inherited lock or a lower count
of lock statements does not establish necessity or minimality.

For example, a worker can publish its successful result while another thread
settles its logical observation as cancelled. Updating the result together with
the worker-recorded marker prevents the later logical snapshot from replacing
that success with the cancellation. A separate owner decision may simultaneously
need the physical-completion fact and the current custody state.

| Protected state or operation | Actual readers and writers | Required atomic relationship |
| --- | --- | --- |
| Worker result, error and recorded marker | Worker publication; Task completion callbacks; owner snapshots | Record the tuple together; observation fallback must test the latest marker before replacing values. |
| Physical/logical completion and watch error | Completion callbacks; polling owner; release/resolution decisions | Keep physical evidence monotonic and snapshots coherent; combine completion with domain guards under the same mutex. |
| Started, returned handle, positive rejection and admission uncertainty | Worker entry; submitter rejection callback; submission caller; owner | Classify refusal from the same attempt's evidence without confusing a missing handle with non-admission. |
| Active identity and observer membership | Owner reserve/join/retire; caller registration; completion-driven observer removal; shutdown reporting | Keep membership changes and exact-attempt removal consistent; closing one observer must not discard physical custody. |
| Domain state combined with completion | Serial owner writes; caller-side receipt reads; worker/callback fact publication | Keep each owner's application, continuation and release preconditions consistent with the shared facts it observes. |
| Original worker diagnostic | Worker publication and receipt construction | Preserve the original diagnostic with its worker fact; the internal hook performs only bounded bookkeeping. |

The concrete concurrency routes are visible in `engine/concurrency/offload_pool.rb`
(worker threads), `execution/task_result.rb` (callbacks on the settling or
registering thread), and `execution/concurrency/physical_completion_task.rb`
(physical callbacks). The public recovery APIs call `observe` before posting
owner work. Agent and Workflow registries assert serial EventLoop delivery for
the subsequent domain decisions; they do not serialize every earlier observer
or worker callback.

The manager receives the operation's existing mutex and passes the same object
to its completion records. That choice preserves compound owner/fact decisions
without introducing a new lock order. Immutable attempt identities and kinds do
not need independent locks. This responsibility analysis does not certify every
unrelated synchronization site in the surrounding owners as minimal.

## Submission, notification and refresh boundaries

The shared protocol separates protected fact changes from calls that can execute
callbacks or access external task state. Submission attaches its returned handle
once; notification binding uses that retained handle. Refresh captures the exact
completion record and handle together before consulting the task.

For example, registering on an already completed task can invoke its callback
before registration returns. The callback can safely publish facts and notify
an owner because registration is outside the owner mutex. If a task snapshot is
read while a worker records success, the later merge honors the newer worker
record instead of overwriting it with the older logical observation.

1. The owner authorizes and reserves work under its mutex. Submission and the
   worker body run outside it. Entry, rejection, returned handle and worker facts
   are recorded through the shared mutation commands.
2. `RetainedAttempts#watch` captures the completion record and retained handle
   under one lock. `AttemptCompletion#watch` binds callbacks without reattaching
   the handle. Task calls and owner notifications remain outside the mutex.
3. `RetainedAttempts#refresh` captures the record and handle under one lock.
   `AttemptCompletion#refresh` reads the task outside the lock, then merges the
   observation with current completion facts under the same owner mutex only if
   that handle is still retained. A release during polling prevents the old poll
   from repopulating cleared result/error references.
4. Callback-registration failure retains the handle and registration error.
   A callback already installed before an exception remains valid. A callback
   retaining an old completion record cannot publish into a replacement attempt;
   owner delivery still uses the original attempt identity.

The former preparation-time reattachment in `PhysicalAttempt#watch` and the
separate slot/handle capture locks in refresh are removed from this protocol.
This is a simplification of the protection boundary, not a runtime performance
claim. Task reads must not be moved inside the owner mutex to merge critical
sections: task methods can acquire their own locks or trigger immediate callbacks.

The optional worker-recorded hook preserves the Approval and Dispatch owners'
original error bookkeeping inside the existing atomic update. Its current
implementation is a conditional assignment. It must not perform I/O, call tasks,
submit work, acquire the owner mutex again or make domain transitions.

## Implementation and model correspondence

The finite models describe owner, worker and observer transitions independently
of the Ruby object layout. The shared classes implement common facts; the domain
owners retain the model actions that interpret proof, apply state and continue
or release work. A model run does not establish a Ruby refinement proof.

For example, a model can forbid releasing custody before physical completion.
Ruby tests must still force a logical callback and a worker publication to race,
or make callback registration fail after installation, to establish how the
implementation preserves the modeled facts.

| Existing model family | Settings | Current implementation correspondence |
| --- | ---: | --- |
| [Workflow terminal reconciliation](../../spec/models/workflow_terminal_reconciliation/README.md) | 44 | Request/read identity and worker observations use `RetainedAttempts`/`AttemptCompletion`; custody acceptance, classification, application and segment release stay in Workflow. |
| [Agent terminal recovery](../../spec/models/agent_terminal_recovery/README.md) | 27 | One recovery lane and `CaptureWorker` facts use the shared classes; `ApplyPost` and `ReleasePost` remain with the Agent coordinator/registry. |
| [Agent terminal submission](../../spec/models/agent_terminal_submission/README.md) | 28 | Common attempt facts support the original owner's separate submission knowledge; accepted first-work authority and retry mode remain Agent decisions. |
| [Approval decision recovery](../../spec/models/approval_decision_recovery/README.md) | 29 | Save/read facts and independent receipt observers use the common manager; wait restoration, partial continuation and handoff remain Approval decisions. |
| [Dispatch preparation recovery](../../spec/models/dispatch_preparation_recovery/README.md) | 59 | Save/recovery worker facts and observers use the common manager; exact proposal, cancellation and once-only dispatch continuation remain Dispatch decisions. |
| [Recovery submission custody](../../spec/models/recovery_submission_custody/README.md) | 14 | `Enter`/`Record`, `ReturnHandle`/`ObservePhysical` and exact-lane retention map to the shared protocol; domain `Apply`/`Release` stay outside it. |

These 201 configurations include positive properties, intentionally defective
variants, witnesses and missing-premise checks. Success means each expected
outcome is matched, including the named counterexamples. Existing model inputs
remain unchanged by the object-layout and lock-boundary cleanup. Delivery
evidence records any fresh execution and exact hashes separately.

The released-handle guard tightens internal reference cleanup when a poll is
already in flight. It does not introduce a new domain state or change the
modeled release authority; its concrete interleaving is covered in Ruby tests.

The models do not enumerate mutex acquisition, Ruby callback registration order,
partial registration or payload aliasing. Deterministic implementation tests
cover inline callbacks, worker-result precedence, monotonic physical evidence,
old-attempt isolation, observer cancellation, partial notification installation,
returned/unknown/refused submission and reference release. A future change to
admission, application or release linearization must revisit the affected model
transition and its progress premises before relying on the old results.

## Compatibility and architecture acceptance

The common implementation follows existing Agent-to-Execution and
Workflow-to-Execution dependencies. Domain authority remains with the consumer;
the common code receives an execution connection instead of selecting Runtime,
Store or an Engine implementation. Applications retain the existing public APIs.

For example, the complete application functions in
[Agent terminal recovery](agent-terminal-recovery.md) and
[Workflow terminal reconciliation](workflow-terminal-reconciliation.md) require
no new manager object or callback. Their recovery policies remain explicit; the
maintenance benefit is one implementation of attempt and observation rules
inside the framework.

Acceptance uses actual source/RBS dependency extraction, boundary checks, source
cycle differences, loader/API checks and real owner/Runtime tests. Existing
conceptual arrows do not prove a new candidate passes those checks. Contract
diagram labels or metadata must be reviewed if adopted responsibilities change;
private class movement alone is not a reason to claim a new architectural layer.

The shared protocol replaces duplicated bookkeeping in four actual owners. It
does not unify their business state machines, create a public Job API, establish
arbitrary backend settlement, complete Handoff applicability or implement
post-stop takeover. The original Agent-only extraction and its measured cost
remain documented as history in [recovery physical facts](recovery-physical-attempt.md).
