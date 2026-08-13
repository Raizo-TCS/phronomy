# Phronomy — Design Decision Log

A record of design decisions and their rationale. Use this as a reference when revisiting decisions later.

---

## Decision 1: Adopt RubyLLM as the LLM abstraction layer

**Situation**: Needed to choose between a custom implementation and RubyLLM as the backend for Phronomy.

**Choice**: Adopt RubyLLM.

**Rationale**:
- Provider support is already implemented, reducing Phronomy's development cost.
- Rails/ActiveRecord integration, streaming, and model registry cover foundations Phronomy needs.
- Natural Ruby DSL code aligns well with Phronomy's DSL.
- Focusing on Agent/Workflow semantics provides better return than rebuilding provider clients.

**Trade-offs**:
- RubyLLM API changes must be tracked.
- Providers outside RubyLLM may lag.
- `Phronomy::LLMAdapter::Base` keeps the provider boundary replaceable.

---

## Decision 2: Manage state as immutable objects

**Situation**: Needed to choose between mutable hashes and immutable objects for Workflow state management.

**Choice**: `State#merge` immutably returns a new object.

**Rationale**:
- Checkpoint saving and comparison are easier.
- Accidental cross-node mutation is reduced.
- History tracking and debugging are clearer.
- Parallel logical execution has fewer shared-mutation hazards.

**Trade-offs**:
- State updates copy objects.
- Initial implementation favors shallow immutable transitions over deep-copy complexity.

---

## Decision 3: Use `>>` operator for Chain composition (`|` as alias)

**Situation**: Needed a Ruby composition syntax inspired by LCEL.

**Choice**: `>>` is primary and `|` remains an alias.

**Rationale**:
- `>>` is consistent with Ruby `Proc#>>` function composition.
- `|` remains familiar to LangChain users.

---

## Decision 4: Implement the Workflow graph runtime in-house

**Situation**: General graph gems do not model stateful Agent execution, checkpoints, suspension, or events well.

**Choice**: Maintain the specialized Workflow/FSM execution engine in Phronomy.

**Rationale**:
- Agent lifecycle semantics are more important than general graph algorithms.
- Explicit state/event behavior integrates directly with persistence and suspension.

**Trade-offs**:
- Runtime correctness remains a framework responsibility.

---

## Decision 5: Unify memory scope by thread

**Situation**: Needed a simple durable context scope before adding multi-level memory.

**Choice**: Use `thread_id` as the primary conversation/session scope.

**Rationale**:
- It covers the common conversation lifecycle.
- Applications may map domain identities such as user IDs onto thread IDs.

---

## Decision 6: Security — Tool execution is no-sandbox by default

**Situation**: Process sandboxing would add deployment-specific dependencies to the core framework.

**Choice**: No sandbox by default. Use approval policy, guardrails, and application-owned deployment isolation.

**Risk mitigation**:
- Irreversible operations should require approval.
- Shell/process capabilities are application-defined rather than implicitly enabled.

---

## Decision 7: EventLoop/FSMSession owns lifecycle; OffloadPool owns synchronous offload

**Situation**: Phronomy needs many concurrently waiting Agent, Workflow, Tool,
and MultiAgent lifecycles without one OS Thread per logical task. It also needs a
bounded place for synchronous work that must not block EventLoop.

**Choice**: Framework lifecycle coordination uses one Runtime-owned EventLoop and
explicit FSMSession state/events. `Phronomy::Task` is only a completion handle.
Synchronous work that cannot safely run on EventLoop uses the bounded
`OffloadPool`.

Tool execution classification is deliberately limited to:

```text
:cooperative
:offloaded
```

The application decides whether work is safe on EventLoop. The framework does
not separately classify I/O-bound, CPU-bound, or process work. Blocking I/O,
CPU-bound synchronous Ruby work, and other long synchronous calls may all use
`:offloaded`.

**Rationale**:
- Waiting for another Agent, approval, timer, or event does not require an OS Thread.
- Agent/Workflow/Tool/MultiAgent share one explicit continuation model.
- The distinction Phronomy must enforce is EventLoop-safe versus off-EventLoop, not I/O versus CPU.
- A bounded shared OffloadPool provides backpressure without inventing a separate executor taxonomy prematurely.
- Named pools allow applications to isolate workloads when shared capacity is insufficient.

**Trade-offs**:
- FSM actions must return promptly and explicitly model later completion events.
- Applications own `offload_pool_size`, queue sizing, and workload-mix capacity planning.
- Thread offload does not provide CPU isolation, remove CRuby GVL contention, or guarantee I/O/CPU fairness.
- A future subprocess offload facility may add stronger CPU/process isolation without changing the Tool execution-mode contract.
- Synchronous public wrappers must not be called from the EventLoop thread.

See ADR-010 for the authoritative current concurrency model.

---

*References: 00_design_philosophy.md, 01_rubyllm_evaluation.md, AI Agent Design Guide 02-scope.md*
