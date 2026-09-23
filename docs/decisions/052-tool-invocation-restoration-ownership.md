# ADR-052: Tool Invocation Restoration Ownership

**Status**: Accepted on the architecture refactoring branch
**Date**: 2026-09-22
**Refines**: [046-agent-responsibility-layout-and-shared-records](046-agent-responsibility-layout-and-shared-records.md)
and [047-recovered-execution-continuation-contract](047-recovered-execution-continuation-contract.md).

## Problem

InvocationRestorer decoded saved Tool batches and directly assigned
ToolInvocation's status, result, authorization decision and approval evidence.
Moving restoration into its own module in ADR-046 left that knowledge of another
object's representation intact. ADR-047 explicitly retained it as separate work.
A change to ToolInvocation's state representation therefore required Recovery to
track its instance variables as well as the saved format.

## Decision

Keep the existing classes and introduce the internal
`ToolInvocation#restore_state!(status:, result: nil, approval_item: nil)` operation.
It is Ruby-public for the Recovery caller and classified `@api private`; it is
not an Application extension SPI. Its input is materialized semantic state,
not an Execution record or a persistence repository.

InvocationRestorer retains saved snapshot key normalization, Tool Call and Tool
lookup, construction of ordinary or missing-Tool invocations, and matching the
approval item by invocation ID. It converts the saved status to a Symbol and
passes the saved result and matched approval item to the newly constructed
ToolInvocation. No ToolInvocation instance variable is assigned by Recovery.
The separate AgentInvocation batch-ID assignment is outside this change.

ToolInvocation owns the supported-state dispatch and approval evidence copy:

| Saved state | Existing behavior retained |
| --- | --- |
| awaiting_approval | Validate arguments unless already terminal, restore require_approval and the waiting state |
| authorized | Validate arguments unless already terminal, restore allow and the authorized state |
| completed | Restore the saved result, including nil or false, and completed state |
| rejected | Restore rejection and its decision |
| failed | Restore the existing generic Tool preflight failure |
| cancelled | Restore cancellation |
| Other state | Raise ExecutionRehydrationRequiredError before applying approval evidence |

The entry method reads as saved-state application followed by saved approval
evidence application. Private methods contain each operation's implementation.
Evidence copying preserves the existing immutable facts and reason semantics,
including an explicit nil facts value. A missing approval item leaves constructor
defaults intact. Saved display evidence is not a new policy evaluation input.

The caller supplies a newly constructed invocation before session installation.
This is not a general rollback or arbitrary live-state replacement interface.
The existing EventLoop ownership and continuation validation remain unchanged.
The old internal `InvocationRestorer.restore_tool_snapshot!` entry is removed;
no forwarding compatibility wrapper is introduced for this private helper.

## Compatibility and limits

No public API, RBS contract, saved schema, approval decision, external replay
eligibility, missing-Tool rule, or callback sequence changes. The existing
validation behavior is retained, including the handling of current Tool
validation errors and missing definitions; this refactor does not add a new
schema-migration or saved-state validation policy. It does not restore arbitrary
Application Tool instance variables.

Restoration itself does not run authorization policy, execute a Tool, acquire a
Runtime, perform persistence I/O or notify listeners. This does not suppress the
existing recovery installation notification of an outstanding approval request.
Load-time notification and later approval/rejection dispatch keep their existing
owners. External outcome-unknown resolution and framework operation recovery
remain with RecoveryCoordinator and the execution owner.

Under [018-durability-guarantees-and-failure-model](018-durability-guarantees-and-failure-model.md),
this change concerns operation-local reconstruction from already materialized
facts. Unsupported input is an F0 rejection without X0 dispatch by this operation.
Same logical execution resumption after F4 remains CONDITIONAL on the existing
confirmed saved state and operation-specific recovery contract. F1 outcome
resolution is unchanged. No new external-effect exactly-once guarantee follows.

## Verification

Replace tests that mock another object's instance-variable writes with real
ToolInvocation behavior tests. Run identical assertions against the old owner
boundary and the new operation. Cover all six states, unsupported states, saved
results, missing definitions, immutable approval evidence, and dispatch gating
before and after approval. Existing restart tests exercise approval and rejection
through actual recovery installation and session continuation. Run the ordinary
and integration suites, API snapshot, annotations, RBS, examples and SQLite
persistence checks. No test count implies a stronger F4 or X0 guarantee.

SharedState coordination ownership, Storage domain responsibilities and Workflow
terminal persistence remain separate work. This decision completes only the Tool
restoration ownership item carried forward by ADR-047.
