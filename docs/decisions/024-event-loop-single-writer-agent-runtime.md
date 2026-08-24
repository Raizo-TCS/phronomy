# ADR-024: EventLoop Single-Writer Agent Runtime State

**Status**: Accepted
**Date**: 2026-08-24
**Partially supersedes**: [ADR-014](014-unified-persistence-durable-state.md) for live Agent Runtime ownership and `AgentExecutionActivation`
**Complements**: [ADR-010](010-cooperative-first-concurrency.md), [ADR-012](012-canonical-execution-log-and-context-policy.md), [ADR-018](018-durability-guarantees-and-failure-model.md), [ADR-022](022-agent-execution-parent-identity-and-runtime-routing-boundary.md), [ADR-023](023-fsm-session-incarnation-identity-and-routing.md)

---

## Context

ADR-014 correctly separated durable Persistence from process-local Agent continuation state, but its implementation introduced `AgentExecutionActivation` and `ActivationRegistry` as a shared mutable Runtime container. The Activation was protected by a Mutex and was mutated from EventLoop, OffloadPool workers, and asynchronous completion callbacks.

That model prevents one component from being the unambiguous live-state authority. In particular, Agent durable preparation and terminal commit paths could successfully persist a transition and then directly mutate live `AgentExecution`, `AgentRoot`, Journal projection, Provider-call state, or Runtime projection from an OffloadPool worker.

CG-03b / ADR-023 established the prerequisite routing foundation: every concrete Agent/Tool/Multi-Agent FSMSession owns a fresh Runtime incarnation identity and asynchronous completion is routed through that session's local EventSink. ACS-11 closes the remaining state-ownership gap.

## Decision

### EventLoop is the single writer of Phronomy-managed live Agent execution state

All Phronomy-managed live mutation associated with an active Agent execution is applied on the Runtime EventLoop thread.

The Runtime no longer owns an `ActivationRegistry`, and `AgentExecutionActivation` is removed. EventLoop owns a process-local execution directory:

```text
execution_id
  -> immutable AgentExecutionState value
       agent
       coordinator
       current AgentExecution
       current RuntimeProjection
       base Manifest
       current AgentInvocation
       current owning fsm_session_id
```

The directory is the mutable authority. Individual entries are immutable values and are replaced atomically on EventLoop rather than mutated in place.

External live-owner lookup does not expose this state. `Runtime#__agent_execution_owner` returns only a read-only process-local owner view sufficient to resolve the current Agent/coordinator and execution status.

### AgentInvocation owns FSM-local mutable invocation facts

Mutable facts that are meaningful only while one Agent FSMSession progresses belong to `AgentInvocation` and are mutated only from EventLoop-driven FSM handling. These include:

- the active Provider Call provenance;
- uncommitted Provider outcomes;
- uncommitted Tool/runtime events;
- application callback failure state;
- Tool batch and approval-resume state.

This is not a replacement Activation. `AgentInvocation` is the FSM context of one logical Agent execution and is not shared as a worker-side mutable authority.

### OffloadPool receives operation-specific snapshots and returns operation-specific results

Synchronous Persistence I/O and other long synchronous work remain off EventLoop. Each operation captures the value data it needs before submission. Hash, Array, and String command data is recursively copied/frozen at the Tool authorization worker boundary.

A worker command may also carry an explicitly classified Application-owned behavior handle, such as an approval-policy callable. Such a callable is executable behavior, not Phronomy live-state authority. Phronomy does not place live Agent, Tool, ToolInvocation, FSMSession, Runtime, EventLoop, or other Phronomy-managed live domain objects into the callable's command/request data.

Application-defined opaque objects embedded in Application-owned context/metadata are not given a complete general value-type protocol by ACS-11. They remain Application-owned and must be safe for the Application's chosen worker usage. General serialization/value-type enforcement for those opaque objects is deferred hardening.

The Agent pipeline uses distinct operation shapes for at least:

```text
InitialPreparationCommand -> InitialPreparationResult
FollowupPreparationCommand -> FollowupPreparationResult
ResumeCommitCommand -> ResumeCommitResult
TerminalCommitCommand -> TerminalOutcome
```

A worker may perform blocking Persistence I/O and operation-local calculation. It must not call live-state mutation hooks such as EventLoop execution replacement, Agent root replacement, Journal live-view append, or AgentInvocation runtime-fact acknowledgement.

After worker completion, a lightweight callback posts the result to EventLoop. EventLoop validates authority and only then applies the committed result to live state.

### Durable commit and live apply are distinct phases

Persistence is the last committed durable representation and recovery source. Successful Persistence operations return the resulting immutable durable values to EventLoop; they do not make Persistence the live read authority.

The normal path remains:

```text
EventLoop-owned live snapshot
        -> OffloadPool durable operation
        -> optimistic durable commit
        -> operation result
        -> EventLoop authority validation
        -> EventLoop live apply
```

Mutable Agent root, execution, and Journal state are not reloaded from Persistence merely to obtain freshness. Existing revision and Agent watermark checks remain the conflict boundary.

### Provider result authority uses FSMSession state and `llm_call_id`

A Provider Call receives its semantic `llm_call_id` on EventLoop before transport begins. Provider completion and streaming chunks carry that ID back through the owning FSMSession EventSink.

A result is applicable only when the Runtime still recognizes the owning FSMSession incarnation and the AgentInvocation still has the same active `llm_call_id` in the required FSM state.

A result for an old Provider Call is consumed as stale and does not advance the FSM. A callback targeting an old FSMSession incarnation is rejected by the session-local routing boundary established by ADR-023.

Phronomy does not introduce a generic generation token, generic invocation ID, or Offload operation identity as a second semantic authority.

### Tool worker results use the same direction of ownership

Tool authorization and execution continue to settle through explicit FSMSession events. Authorization worker input is captured on EventLoop before submission. Its value data contains Agent identity metadata and Tool description/operation data, not live Agent or Tool objects. Tool authorization behavior (`approval_facts`, `requires_approval`, and Agent approval policy when callable) is captured as explicitly classified Application-owned behavior handles.

`ApprovalEvaluationRequest` is therefore a value-only policy input. It exposes `agent_id`, `agent_definition_id`, `agent_definition_version`, execution identity, Tool name/schema, arguments, facts, context, origin, metadata, and default decision; it does not expose live `agent` or `tool` references.

Actual Tool execution is a separate behavior boundary: executing the configured Tool is the purpose of that operation. The authorization worker does not need the Tool instance and must not use one as live authorization input.

Authorization/execution outcomes are immutable result carriers and are applied to `ToolInvocation` only by EventLoop-driven FSM handling. They carry `tool_invocation_id`; EventLoop-driven Tool FSM handling consumes an outcome as stale when that semantic ID does not match the current ToolInvocation. `tool_invocation_id` remains the semantic Tool-operation identity. FSMSession identity remains Runtime routing identity. The two are not conflated.

### Approval suspension retains the same live owner without Activation

Approval suspension retains the same process-local Agent and AgentInvocation. The suspended execution remains present in EventLoop's execution directory, but no active FSMSession owns it while suspended.

`Agent::Base.live_for_execution(execution_id)` and `agent.approve_async(...)` resolve the process-local execution owner through EventLoop's read-only owner view. They do not load a replacement Agent/Execution from Persistence.

A resume performs its durable approval transition off EventLoop and applies the result on EventLoop before constructing a fresh resume FSMSession incarnation.

If no live owner exists, durable rehydration remains a separate capability and `ExecutionRehydrationRequiredError` is raised.

### Application callbacks do not become a worker-side authority

Application stream/event callbacks are invoked from EventLoop-owned AgentInvocation event handling. Callback failure is recorded independently of canonical runtime event capture, converted into an explicit FSM failure event, and cannot mutate durable or live execution state from an Offload worker.

Approval notification callbacks may execute off EventLoop because they are application work. Their execution does not advance Phronomy-managed live state.

## Required invariants

The implementation must preserve all of the following:

1. Journal / Manifest / ContentStore remain the canonical execution/context record authorities defined by ADR-012.
2. Persistence remains the durable recovery authority, not the normal live refresh source.
3. FSMSession incarnation identity and EventSink routing remain as defined by ADR-023.
4. `execution_id` remains the logical Agent execution parent identity defined by ADR-022.
5. Provider result authority is checked with current FSMSession/FSM state plus `llm_call_id`.
6. Tool result authority remains tied to the current Tool FSMSession and `tool_invocation_id`.
7. OffloadPool never waits synchronously for logical EventLoop progress.
8. Worker completion callbacks do not fall back to direct live mutation when EventLoop is unavailable.
9. Tool authorization command/request value data contains no Phronomy-managed live domain object; explicitly classified Application-owned behavior handles remain permitted.

## Consequences

### Positive

- Agent live-state ownership is explicit and mechanically enforceable.
- Mutex-protected shared Activation state disappears.
- Worker-side durable I/O can scale independently without becoming a second live-state writer.
- Late Provider results cannot overwrite the provenance of a newer Provider Call.
- Approval lookup remains process-local without exposing mutable execution internals.
- The design provides the state/result foundation required by later recovery, cancellation, and durable-barrier work.

### Trade-offs

- Durable commit and EventLoop live apply are separate phases, so code must explicitly model and validate result application.
- Internal Agent execution coordination uses more typed command/result values than the Activation model.
- Process loss still loses in-flight Runtime continuation; this decision does not implement rehydration.

## Explicitly deferred work

This decision does **not** implement:

- ACS-12: same-process Agent admission/exclusion policy;
- ACS-13: opaque Workflow admission ownership and Workflow terminal-save ordering;
- ACS-14: cross-process leases/fencing;
- ACS-15: durable Agent/FSMSession rehydration;
- ACS-16: cancellation/HITL Task semantic completion;
- ACS-17: semantic retry and causal durable barriers.

Those changes build on this ownership/result model and must not be folded into ACS-11 implicitly.

## Rejected alternatives

### Rename Activation and keep the same shared mutable object

Rejected. A renamed mutex-protected container shared by EventLoop and workers preserves the ownership defect.

### Let workers update Agent live state after a successful commit

Rejected. Successful durability does not grant a worker live mutation authority. The result must return to EventLoop for apply.

### Reload Agent state from Persistence before every apply

Rejected. This would make Persistence the live source of truth and reintroduce implicit refresh/merge semantics rejected by ADR-014.

### Add a generic generation/correlation token

Rejected. Result authority is expressed using the current FSM state plus existing purpose-specific semantic identifiers. A new generic token would recreate identity ambiguity already removed by ADR-021 through ADR-023.
