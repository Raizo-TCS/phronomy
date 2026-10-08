# ADR-063: Execution Contracts, Services and Engine Internals

> Historical decision. Superseded by [r8 unit 1](../architecture/r8-unit1.md): Execution contracts and services are now united, with mechanism binding in Engine.

**Status**: Accepted for implementation
**Date**: 2026-09-28
**Refines**: [038-source-layout](038-responsibility-based-source-layout.md),
[045-worker-input](045-worker-input-restriction-ownership.md) and
[059-backend-groups](059-backend-contracts-and-async-clients.md)

## Problem

Engine grouped public result/call APIs, shared value/error/marker contracts and
private schedulers together. A WorkerInputRestricted include or an RBS token
reference consequently appeared to be a dependency on worker machinery.
ToolBinding also implemented its own result transformation. It forwarded the
source's physical-completion signal before the result filter had finished;
Agent execution quiescence could therefore observe an incomplete transformation
as physically complete.

## Decision

Keep public constants and split source ownership into three responsibility groups:

| Group | Directory | Owns |
|---|---|---|
| G58 Execution Contracts | `execution_contract/`, `execution_contract/concurrency/` | Runnable, InvocationContext, Event, FSMProtocol, shared failures, CancellationToken and WorkerInputRestricted |
| G59 Execution Services | `execution_services/` | TaskResult, Execution, Blocking, and outcome-bearing execution errors |
| G14 Engine Internals | `engine/`, `engine/concurrency/`, `engine/runtime/` | Runtime, EventLoop, FSMSession, receivers, pools, queues and control/result-composition machinery |

Zeitwerk collapses the two new root directories. Existing `Phronomy::*` and
`Phronomy::Concurrency::*` constants keep their identity, signatures and
behavior. No new public namespace or forwarding file is introduced. Public RBS
declarations remain in `sig/` but follow their actual source owners.

Contracts may depend only on Execution Contracts and Common responsibilities,
including neutral RuntimeSettings. This is a boundary contract, not a claim
that every class is methodless: CancellationToken retains its existing state
and callbacks, and Runnable retains its default tracing switch. InvocationContext
can carry opaque execution bindings without constructing a scheduler.

Execution Services contain real implementation. TaskResult uses Engine's result
composition and wait guards; Engine pools create TaskResults. This mutual
dependency remains explicit. The split does not assert an acyclic layer
hierarchy. Backend Contracts and implementations may not reach either services
or Engine, including through RBS references.

ToolBinding delegates callback-based transformation to a private TaskResult
entry point backed by ResultComposition. Physical completion now requires both
source physical completion and transformation completion. The callback-only
path preserves custom result handles, failure identity, name, no inherited
execution scope, and the existing behavior that cancelling the filtered result
does not cancel its source or suppress the later filter. Public map/flat_map
scope and parent semantics are unchanged.

Tracing finish and approval notification use Blocking.call_async for generic
default-pool work. Both observe the returned failure because Blocking converts
admission errors into failed results. Approval callbacks that fail after dispatch
are now also logged. Checks that only ask whether code runs on EventLoop use
Runtime.in_event_loop_context?, avoiding construction of a Runtime merely to
answer that question.

## Retained direct dependencies

AsyncClients are execution bridges and retain Runtime/pool access, specialized
pools, tokens and result types. Agent/Workflow runners and registries still own
FSM sessions, control delivery, single-writer state and lifecycle coordination.
Replacing these with a generic wrapper would conceal required ownership rather
than remove it. Registry receiver lookup is not redesigned in this change.
See the [usage inventory](../architecture/execution-boundaries.md).

## Compatibility and verification

`require "phronomy"` remains the public loading contract. Old implementation
file paths move without compatibility shims. Public signatures and API snapshot,
transactions, pool admission policy and timeout/cancellation ownership are
unchanged. No backend author must implement another async method.

Test blocked success/failure filters against a real pool, cancellation and custom
completion handles; rejected tracing/approval dispatch and asynchronous callback
failure; standalone marker loading and eager loading without Runtime creation;
the public signatures and full Ruby/RBS boundary graph. Existing unit,
integration, coverage, style, benchmark and SQLite contracts remain required.

The measured SVG retains B1-B6 display bands, pastel group backgrounds, module
boxes and transparent text. G59 is in B4 and G58 in B5; these positions grant
no dependency permission. Incoming M33/M41/M44 arrows remain visually hidden
while every dependency stays in the matrix, audit and boundary checks.
