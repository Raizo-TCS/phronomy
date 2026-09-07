# Durable continuation decision ownership

Date: 2026-09-07
Baseline: `c383b64b26e702291e288476e0978641a1c1512f`

## Problem

Recovery previously chose its next action twice: once using transient
`ResolutionResult.continuation` after a factual resolution, and again using
phase-specific restart branches. A mixed Provider response exposed the gap:
`recovery_tools_completed` could still have framework calls pending, but the
restart branch started a Provider follow-up without executing them.

Team also interpreted a child result immediately and independently reread its
saved error references on restart. Cancelled Agent executions carry an error
reference too. Interpreting the reference as failure changed Team cancellation
into failure. Earlier code could lose a saved failure after a crash between
child-result recording and Team terminalization.

## Decision ownership

`RecoveryCoordinator::Continuation#recovery_action` derives the next action
from the saved AgentExecution and the current compatible framework wiring.
Both factual resolution apply (including F1 readback) and automatic restart
continuation call `continue_recovery_on_event_loop`. Invocation reconstruction,
Provider output materialization, pending framework calls, session registration
and terminal failure handling are shared.

`ResolutionResult` carries only the committed execution. It does not carry a
second continuation label or a transient copy of the failure. The existing
execution metadata remains the authority after both F1 and F4.

| Saved facts | Continuation |
| --- | --- |
| Authorized, replayable framework batch with external facts already settled | Reconstruct the existing Tool sessions and exact owned operations |
| `recovery_provider_completed`, framework calls pending | Restore the saved framework calls and enter normal Tool dispatch |
| `recovery_provider_completed`, no framework calls pending | Apply output filtering and finish through the Agent terminal barrier |
| `recovery_tools_completed`, framework calls pending | Restore the saved framework calls and enter normal Tool dispatch |
| `recovery_tools_completed`, no framework calls pending | Start the Provider follow-up through normal preparation |
| `recovery_resolved_failed` | Materialize the saved failure and use the Agent terminal barrier |
| Unresolved external Provider/Tool fact | Deliver the existing factual-resolution request |

Initial preparation and approval rejection keep their operation-specific entry
points. Approval waiting remains suspended. Classification still decides whether
an execution can be installed automatically; it does not implement an alternative
continuation for the resolved states above.

## Team decisions

`TeamCoordinator#next_run_action` derives a decision from durable Team records.
Normal execution records the child outcome and returns to this decision, using
the same path as `resume`. It does not separately terminalize from a local
`outcome[:error]` value.

Decision order:

1. Reconcile the coordinator or an existing reserved assignment through exact
   Agent execution identity and the existing cancellation/recovery machinery.
2. Preserve a coordinator `failed` outcome, or a worker `failed` outcome when
   `on_error: :raise` is saved.
3. Honor the saved cancellation request or a child's explicit `cancelled` state.
4. Reserve unassigned work, or aggregate when no work remains.

`error_ref` contains diagnostic material; the child `state` defines whether its
outcome is failure or cancellation. A failed worker under `on_error: :skip`
remains a failed assignment available to aggregation. A later Team cancellation
does not rewrite that assignment. A non-skipped committed failure remains a
Team failure even if cancellation is subsequently requested.

A cancelled, absent reservation is retained without starting a child. An already
admitted child whose external outcome requires factual resolution keeps the Team
active and discoverable, including across another restart. Cancellation does not
supply that missing external fact.

## Responsibility and compatibility

- Public APIs, existing persisted statuses/phases and repository schemas remain
  unchanged. No new persisted continuation object or migration is introduced.
- Framework-owned child execution identities, Tool batches and Team assignments
  remain framework recovery responsibilities.
- Unknown external Provider/Tool effects still use the existing application
  factual-resolution contract. Resolution does not redispatch the external effect.
- Scheduler and aggregation remain replay-safe application calculations.
- Runtime observers and callbacks do not acquire durable delivery guarantees.
- Agent, Handoff, Team and Workflow retain the domains established by ADR-029,
  ADR-030 and ADR-031. This change does not add another execution engine.
- Records already terminalized incorrectly by an earlier implementation are not
  rewritten automatically. They require separate, case-specific investigation.

This refactor addresses duplicated Recovery continuation and Team outcome
interpretation. It is not a claim that every state transition across the full
framework has been model-checked. In particular, ordinary execution versus
Handoff terminal-commit organization remains outside this change.

## Regression coverage

### Persistence I/O boundary follow-up

Recovery follows ADR-014/024's prepare/apply boundary. `prepare_plan` reads the
restart inputs at the existing synchronous load boundary, outside EventLoop.
Resolution commit, bounded F1 readback, and subsequent content materialization
run in the existing resolution OffloadPool operation. Approval restoration also
receives its assistant message as prepared material. Invocation and Tool state,
chat wiring, output filtering, and session registration remain on EventLoop.

`RecoveryMaterial` and `ResolutionPreparation` are private, operation-local
results. They are not persisted and carry no alternative continuation decision.
Prepared messages transfer to the new invocation; there is no shared content
cache or new durable identity. The current saved execution still determines
the continuation for both resolution and restart.

If content materialization fails after a confirmed resolution commit, EventLoop
retains the confirmed execution and fails the observer without inventing a
semantic failure or replaying the Provider/Tool. Restart can prepare the same
saved execution again. If F1 readback itself fails or returns conflicting facts,
the observer fails and no continuation starts. A late preparation result must
still match its captured live execution and owner before it can be applied.
Callbacks post back to the originating Runtime; shutdown never grants a worker
permission to mutate live state.

Invocation-owned Orchestrator Tools use the existing durable child Knowledge
snapshot. Tool construction does not read that Knowledge again on EventLoop.
Standalone Tool construction retains its existing caller-side snapshot behavior.

The shared F1/F4 fixture now rejects EventLoop content reads, execution loads,
and transactions. `recovery_io_boundary_spec.rb` additionally covers resolved
output, restart, approval allow/reject, content/readback failures, stale apply,
shutdown, and unrelated Agent progress while content or readback I/O is blocked.
These tests use synchronous InMemory operations and explicit queue barriers;
they do not establish disk durability or production-adapter latency bounds.

`spec/phronomy/multi_agent/durable_continuation_spec.rb` adds 27 examples:

| Coverage | Examples |
| --- | ---: |
| Six executable regressions from the two reviews | 6 |
| Six Provider call compositions, with/without F1 resolution response loss | 12 |
| Coordinator/worker cancellation, before/after Team outcome recording | 4 |
| Skipped worker failure, resumed with/without subsequent cancellation | 1 |
| Provider/Tool failed or not-performed resolutions, F1 and F4 | 4 |

The composition matrix includes no calls, external only, framework only, both
orders of a mixed response, and multiple external calls around a framework call.
Each example resumes snapshots of the Provider response resolution and each
external fact resolution. Framework compositions also resume child reservation
and child terminal snapshots. Assertions cover final results, Provider call
counts, absence of external effect replay, and retention of already reserved
child execution IDs.

The two saved-failure regression examples also test a subsequent cancellation.
The existing durable coordination suite additionally verifies cancellation while
a coordinator still requires external factual resolution, including another
restart. Shared fixtures live under `spec/phronomy/multi_agent/support/` and are
loaded explicitly by the two durable suites.

F4 tests restore committed InMemory DurableRecords in a fresh backend and Runtime;
they do not kill a real OS process or validate every production Persistence
adapter. F1 tests raise after an actual in-memory transaction commit. Provider
responses are supplied by WebMock, with no live LLM calls.
