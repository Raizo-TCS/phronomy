# ADR-045: Worker Input Restriction Ownership

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-21
**Refines**: [024-event-loop-single-writer-agent-runtime](024-event-loop-single-writer-agent-runtime.md)
and [038-responsibility-based-source-layout](038-responsibility-based-source-layout.md)

## Problem

Tool authorization snapshots exclude framework-managed live objects from value
data and application behavior handles. `ToolInvocation` identified those objects
by enumerating 18 Agent, Workflow and execution types. The Agent-side boundary
therefore depended on concrete Workflow types solely to reject them as input.

Moving that list into a shared helper would retain the wrong ownership. Treating
all frozen objects or all callables as safe would weaken the existing boundary;
rejecting all opaque application objects would break ACS-11.

## Decision

1. The execution boundary owns the internal, methodless
   `Concurrency::WorkerInputRestricted` marker in `engine/concurrency/`.
   It declares that instances of an owning type are excluded from the existing
   authorization worker value/behavior boundary. It contains no feature list,
   registration mechanism, class-name matching, constant lookup or callbacks.
2. Each previously restricted type directly includes the marker in its own
   definition. WorkflowContext includes it as a module so implementations and
   their subclasses retain the restriction. Other classes pass it through
   normal Ruby inheritance. Nested types are marked only when they were in
   the original rejection set; marking FSMSession does not mark every nested
   class, so its EventSink opts in separately.
3. `ToolInvocation` checks only `is_a?(Concurrency::WorkerInputRestricted)`.
   Recursive Hash-key/value and Array traversal, String copying/freezing,
   exception type/messages and behavior-handle checks remain unchanged.
   Frozen marked instances remain restricted.
4. Each owner explicitly requires the small marker file. The marker can load
   alone without Agent, Workflow, Runtime or application bootstrap. Normal,
   preloaded, repeated and eager application loading retain marker identity
   and do not create settings or start Runtime. The marker adds no methods to
   public APIs; the existing API snapshot is not regenerated.

## Existing restriction inventory

| Owner | Types that include the marker |
|---|---|
| Agent execution/state | `Agent::Base`, `AgentRoot`, `AgentExecution`, `AgentInvocation`, `ToolInvocation`, `JournalProjection`, `ExecutionCoordinator` (all under Agent) |
| Agent capability | `Agent::Context::Capability::Base` |
| Workflow | `Workflow`, `WorkflowRunner`, `WorkflowContext` |
| Execution | `Runtime`, `TaskResult`, `EventLoop`, `FSMSession`, `FSMSession::EventSink` |
| Concurrency | `Concurrency::CancellationToken`, `Concurrency::OffloadPool` |

These are the same 18 root types as the previous predicate. Regression tests
retain this inventory to prevent an accidentally unmarked existing type from
becoming admissible. Future framework types subject to this boundary must opt
in at their owning definition and add an input-boundary test.

## Scope and compatibility

This marker is internal classification, not a public safety certification or
serialization SPI. It does not reject all Runnable implementations, all
Phronomy objects, class/module objects, or every worker command. Other operation
snapshots and OffloadPool APIs are unchanged.

Application-owned opaque values and behavior handles remain permitted by
identity. Their instance variables, callback receivers and closure captures
are not traversed. Applications remain responsible for worker safety under
the existing ACS-11 contract. The marker is not a security sandbox.

The ancestry of the 18 types intentionally gains one methodless module.
Public methods, constructors, value copying, events, ownership, cancellation,
transaction boundaries, persistence formats and exception behavior are
unchanged. No F1 uncertain-commit reconciliation, F4 recovery, external-effect
rollback or exactly-once guarantee is added.

## Dependency interpretation

The Agent-to-Workflow execution dependency disappears. Workflow types and
Agent types instead refer downward to an execution-boundary contract.
Existing Engine types refer within the execution foundation. Explicit
marker loading adds require edges; it does not move feature references into
the marker. A methodless include is still a real source dependency.

This completes the specific A-E reverse-dependency proposals. It does not
eliminate all directory/file cycles, Storage's domain-specific repository
names, or FSMSession's Workflow terminal persistence responsibilities.

## Verification

Verify the 18-type inventory for direct instances and subclasses, frozen and
unfrozen, root values, Hash keys/values, nested Arrays and all three behavior
handle names. Exercise actual authorization command capture for Workflow,
WorkflowRunner and WorkflowContext via context/policy/facts/requirement paths,
and reject a marked value returned from a facts callable. Preserve opaque
application data, callables and unmarked Runnable/Outcome values.

Also verify a new marked type without changing the evaluator, standalone and
normal/preloaded/eager loading, no Workflow type references in Agent source,
and the marker's absence of feature knowledge. Run the existing snapshot
boundary suite, full and integration tests, style, unchanged API snapshot,
RBS, annotations and examples against the candidate core.
