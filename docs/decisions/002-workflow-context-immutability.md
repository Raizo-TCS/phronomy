# ADR-002: WorkflowContext#merge Returns a New Instance (Immutability Contract)

## Status

Amended

## Context

`WorkflowContext` carries the shared state that flows through workflow nodes.
Two design options existed:

1. **Mutable**: nodes modify state in-place; the same object is passed through
   the entire graph.
2. **Immutable**: `merge` always returns a new instance; nodes return the new
   state rather than mutating the old one.

Mutable state is simpler to implement but creates hazards: parallel node
execution (current or future) would require locking to prevent races. It also
makes debugging harder — it is difficult to track where a field was last changed
without snapshotting state at each step.

## Decision

`WorkflowContext#merge` (and all field writers) return a new `WorkflowContext`
instance. Nodes receive a state object and must return (or yield) a new state
object. The framework replaces the current state with the returned value.

## Consequences

**Positive:**
- Future parallel node execution (fork/join) can safely hand each branch a
  separate copy of the state without defensive copying at the call site.
- Checkpoint/replay for `interrupt_before`/`interrupt_after` is straightforward
  — a checkpoint is just a serialized state value.
- Accidental mutation by a node does not silently corrupt shared state.

**Negative / Tradeoffs:**
- A small allocation overhead per `merge` call. Acceptable at typical workflow
  depth (tens of nodes, not millions).
- Node authors must remember to return the new state; forgetting to do so
  discards the update silently. (Future work: frozen state objects or
  a strict return type could catch this at dev time.)

## Amendment — EventLoop-owned direct field mutation

The original Decision remains normative for `WorkflowContext#merge`, but its
statement that **all field writers** return a new `WorkflowContext` is amended.

Current semantics are:

1. `WorkflowContext#merge` remains a non-mutating, new-instance operation. It
   applies each field's merge policy and returns a replacement
   `WorkflowContext`.
2. Direct generated field writers are controlled mutation APIs. They update the
   current `WorkflowContext` instance only when code is executing under
   Phronomy's Runtime/EventLoop write authority.
3. A direct field write outside EventLoop dispatch authority fails with
   `Phronomy::WorkflowContextOwnershipError`.
4. EventLoop write authority and Ruby object immutability are distinct
   state-management concerns. The single-writer rule does not require every live
   state transition to allocate a replacement Ruby object.
5. This amendment does not introduce or redefine Workflow identity. Durable
   Workflow identity remains `workflow_instance_id`.

The original rationale for value-style `merge` remains useful: application code
can construct replacement state without mutating the source context, while
Runtime-owned event processing may use guarded direct writers when appropriate.
