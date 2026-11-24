# Workflow terminal ownership: design and validation

Implementation baseline: core `01cd2f57549f6d1e60825254f4520d0f123e651c`
(Refactor 32 applied) and examples `2f8b467f1268dd21de4c02b1c90c8bdd211d1feb`,
2026-09-23. W2a and W2b are applied and verified; W2b is core
`fcd434c45ad98e5c93953cbce1ffef3c12246894` (Refactor 33). The adopted private contract is
[ADR-056](../decisions/056-workflow-terminal-policy-ownership.md).

This document records the historical W2a/W2b design and validation, not the current
terminal-recovery API contract. The policy/Engine responsibility separation still
applies. The uncertainty observation, completion-custody and shutdown behavior
below has been superseded by the implemented
[Workflow terminal reconciliation contract](workflow-terminal-reconciliation.md).
That contract supports explicit recovery through the same running or draining
Runtime, retains unresolved responsibility at shutdown, and does not implement
stopped-owner takeover or process-crash recovery. For example, an unknown save
now yields a typed recovery reference instead of leaving the ordinary caller
pending through successful shutdown.

## Role and consumers

FSMSession drives one live state machine on EventLoop. WorkflowRunner assembles
Workflow transitions, stream observation and any durable terminal save.
InvocationActions and EngineSessionBuilder uses the same engine for input, LLM and Tool
progression; ToolInvocationSessionBuilder uses it for authorization, approval
and Tool execution. Therefore the session stays in Engine.

The former leak was narrower: Engine recognized the Workflow persistence event
and interpreted its save outcomes. WorkflowTerminalPolicy now owns that rule.

## Ownership and concrete boundary

| Owner | Responsibility |
|---|---|
| FSMSession | Identity/sink, transitions, live context, pending terminal kind/notification flag, event acceptance and final notification/event ordering. |
| WorkflowTerminalPolicy | Start the injected save callback; recognize the Workflow result event; map its outcome to a generic terminal decision. |
| Phronomy::TerminalDecision | Immutable `action` and `error` value shared by a domain policy and the session. No live session authority. |
| WorkflowRunner | Construct a policy for durable execution; retain snapshot capture, one save, F1 readback and caller completion. |
| WorkflowExecutionRegistry | Admission, owner tokens, session routing binding and recovery-required ownership. |
| EventLoop | Event routing, management events, retirement, source completion and shutdown. |

Runner builds a policy only when both repository and persist are enabled.
Agent, Tool and ephemeral Workflow need no dummy policy or delayed completion.
The policy retains only its persistence callback, with no lifecycle flags.

The three private operations are `start(terminal_type:, context:, event_sink:)`,
`handles?(event)` and `decision_for(event)`. Start does not return completion
permission. The decision value maps Workflow success to `complete`, known
failure to `fail`, and unresolved uncertainty to `retire`. Failure preserves the
original exception or the existing missing-error fallback. Invalid outcomes
remain errors. Engine no longer branches on Workflow's event or outcome values.

FSMSession alone tracks `running`, `awaiting_terminal`, and its final lifecycle
state. Matching early events are discarded before invoking decision_for;
ordinary events cannot advance while awaiting; events after done are ignored.
The retirement action reuses the existing recovery-required management route.

## Preserved durable ordering

1. Session reaches a logical wait/completion boundary and captures metadata.
2. Session marks itself awaiting a decision before invoking the policy.
3. Runner marks admission persisting_terminal and captures an immutable command.
4. Offload saves once and reconciles an uncertain result when possible.
5. The bound EventSink returns the result to that session on EventLoop.
6. The policy interprets the result only while the session accepts it.
7. A complete decision permits the deferred observer, then the terminal event.
8. EventLoop retires the session; Runner releases admission before settling the caller.

An observer exception still uses Refactor 32's ordinary error path, with the
already confirmed snapshot retained. No observer retry or extra save is added.

At the W2b baseline, unresolved uncertainty instead retired the session and
retained recovery-required admission without settling the caller. Normal shutdown
cleared that ownership and ended the dispatcher while the caller remained pending;
unexpected dispatcher failure retained its separate waiter-cleanup behavior.
Those historical observations did not establish that normal shutdown resolved an
unknown commit. They are not the current acceptance requirements: current recovery
keeps the obligation, fails the original observation with a typed recovery error,
and prevents complete cleanup while responsibility remains unresolved.

## Alternatives and compatibility

Moving the full session would introduce Workflow dependencies into Agent/Tool.
Renaming event strings in Engine would leave semantic ownership unchanged.
Subclass/prepend overrides would recreate the hidden execution path removed by
W1. Saving after retirement or settling on a worker would break the barrier.
The injected policy keeps each rule at its existing execution authority.

The internal constructor changes from terminal_barrier to terminal_policy;
there is no compatibility alias or new public plugin API. Without a policy,
Engine does not reserve a Workflow-specific event name. Production Workflow
emits the result event only when it has injected its durable policy.
At W2b, public signatures, Workflow command/result identities, data records and
Storage SPI stayed unchanged. One policy class and one decision value type were
added; this was responsibility separation, not a total-line-count reduction.
The later reconciliation APIs and result types are documented separately in the
[current contract](workflow-terminal-reconciliation.md).

## Historical W2b acceptance evidence

| Scenario | Test boundary |
|---|---|
| Immediate completion/halt and Agent/Tool | Existing Workflow/Agent/Tool suites and generic no-policy completion. |
| Delayed save and halted stream | Real Runtime admission tests prove no early result/notification. |
| Portable failures and F1 post/pre/conflict/unreadable | Existing save tests plus real Runtime pre-state and uncertainty tests. |
| Unknown result and normal shutdown | Admission retained until shutdown, session unbound, caller remains pending. |
| Early/ordinary/duplicate decisions | Non-Workflow policy/session contract and Workflow policy wiring tests. |
| Late sink and new incarnation | Real Runtime rejects an old sink for the same logical Workflow ID. |
| Terminal observer failure | Refactor 32's four public stream regressions. |
| Submission rejection and delivery rejection | Existing error path releases admission; rejected delivery logs without retry. |
| Invalid outcomes and missing error | Workflow policy through the real Runner/session assembly. |
| Load, types, API, gem and source boundary | Full validation and private ownership regression assertions. |

The pre-state, uncertainty/shutdown, stale-sink and rejected-delivery scenarios
also pass on the Refactor 32 baseline; they characterize preserved behavior.
New protocol tests establish the extracted ownership contract. Refactor 33
application verification completed W2b. Storage S1/S2 followed and passed on
Refactor 35; see the [closure review](refactoring-closure.md) for S3 and the
current applied/candidate boundary. The earlier Refactor 32 baseline remains
historical evidence for preserved behavior.
