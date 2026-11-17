# Execution boundary prototype (historical)

This document preserves an earlier source-derived design proposal, including
its original group names and compatibility decisions. It is not a pending
implementation plan or the authority for the current source layout.

For example, the Workflow phase compiler and neutral execution values are
present in the current implementation, while later refinements changed the
prototype's grouping and placement. Use [Phronomy Architecture](architecture.md)
and the current source diagram for the reconciled responsibilities.

Original prototype base: main 653e255a34fe4062d4beca47530e084fdd3a6ba9.
The proposal below is retained as history, not a current public API guide.

## Recorded proposal

The prototype separated result values from concrete execution connections.
For example, Engine and Services could share TaskResult without making those
values acquire Runtime or invoke operation-submission services.

TaskResult, Outcome, result composition, physical completion and ScopeState
belong to Execution Results. They depend on Contracts and Common, without
acquiring Runtime or calling Execution Services. Engine and Services share
these neutral results. OffloadPool uses an injected timer protocol; its wait
guard uses WaitPolicy. Services owns operation binding, timer subscriptions,
worker submission and invocation-control adaptation.

Workflow::Completion owns the public DSL finish value `:__finish__`.
WorkflowPhaseMachineBuilder, beside WorkflowRunner, translates it to the FSM
terminal state. FSMSession retains terminal detection and persistence gating.
TerminalDecision is an execution contract, independent of Workflow and FSM
state vocabulary.

## Compatibility decisions recorded in the prototype

The prototype moved execution-control adaptation out of shared values and
removed obsolete internal entry points. For example, InvocationContext kept
the supplied deadline value while the invoking service attached its timer.

* InvocationContext#effective_timeout_token and #effective_cancellation_token
  are removed. Although annotated private, both occurred in the Stable API
  snapshot. This candidate updates those two entries explicitly. Applications
  pass cancellation_token/deadline into InvocationContext; the invoking
  service applies them. Code needing a standalone token constructs
  Concurrency::CancellationToken directly.
* Deadline#attach_to is removed. Deadline is a time value, not a timer owner.
  Internal Workflow control adaptation moves to InvocationControls.
* Unused private CancellationScope is removed. Private
  Workflow::PhaseMachineBuilder becomes WorkflowPhaseMachineBuilder in the
  Runner source directory. FSMProtocol::TerminalDecision becomes
  Phronomy::TerminalDecision. Direct requires of moved internal files change.
* An already expired Workflow deadline now cancels immediately. An explicitly
  supplied token still takes precedence over that deadline, as before.

TaskResult/map/flat_map/all_settled and AsyncClient public operations remain.
WorkerSubmission preserves injected-pool ownership, original result identity,
operation-time Runtime resolution and synchronous admission errors. Blocking
continues converting admission errors to failed results. MCP keeps its named
cleanup pool. Engine connections remain with registries/coordinators/runners.

RBS declares scope, timer, receiver and terminal-policy protocols in sig/.
Validation checks signature consistency, not whole-program type correctness.
The static diagram includes Ruby and RBS evidence; injected implementations
and callback behavior also require runtime tests.
