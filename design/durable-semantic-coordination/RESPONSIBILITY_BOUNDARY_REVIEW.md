# Phronomy Durability Responsibility-Boundary Review

Status: Accepted V2 revision 2, 2026-09-06.

## 1. Purpose

The earlier "Complete Durability" plan attempted to make every visible completion
boundary resilient to process loss. That produced technically defensible
protocols, but responsibility analysis showed that several of those protocols
belonged outside the Phronomy semantic execution engine.

This review narrows durability to the state Phronomy **owns and can reconcile
authoritatively**.

The objective is not "persist everything". The objective is:

> Preserve framework-owned semantic progress across process/runtime loss without
> blindly repeating work already known to have completed.

## 2. Responsibility test

A fact belongs to Phronomy durability when all of the following are true:

1. Phronomy creates or owns the semantic operation.
2. Phronomy has a canonical durable identity for that operation.
3. Phronomy can determine its authoritative state from `Persistence`.
4. Repeating the operation after losing Runtime state could duplicate semantic
   work or violate the public abstraction.
5. The required recovery does not require Phronomy to emulate an Application
   transaction coordinator.

A concern remains Application responsibility when one or more of the following
are true:

1. it is an arbitrary callback or external side effect;
2. its exactly-once/idempotency semantics depend on an external system;
3. the Application can naturally handle it with an outbox, job queue,
   idempotency key, database transaction, or its own Workflow;
4. persisting it would force Phronomy to serialize or reconstruct Application
   code/Runtime objects;
5. the API is only a convenience operation and has no existing durable semantic
   root.

## 3. Revised boundary

| Concern | Owner | Restart-spanning guarantee |
|---|---|---|
| AgentExecution semantic status | Phronomy | Yes |
| Agent result/error durable evidence | Phronomy | Yes |
| Agent `on_event` callback invocation | Runtime/Application | No |
| Callback side-effect deduplication | Application | No framework guarantee |
| Handoff active Agent responsibility | Phronomy | Yes |
| Handoff reserved Target execution | Phronomy | Yes |
| Handoff graph/Policy Ruby objects | Application Runtime wiring | Re-supplied, not persisted |
| Orchestrator child reservation/outcome inside an AgentExecution | Phronomy | Yes |
| Standalone `dispatch_parallel` / `fan_out` convenience call | Runtime | No |
| Team task queue | Phronomy | Yes |
| Team task -> worker assignment | Phronomy | Yes |
| Team worker execution/result | Phronomy | Yes |
| Team scheduler callback | Application pure/replay-safe function | May be rerun before assignment commit |
| Team aggregator callback | Application pure/replay-safe function | May be rerun until result commit |
| Team progress/terminal callback | Runtime/Application | No |
| Email/webhook/DB side effect triggered by a result | Application | Use Application transaction/outbox/idempotency |

## 4. Why restart-spanning `on_event` is removed

The earlier design stored a terminal-delivery descriptor, indexed pending
deliveries, redelivered them from `Agent.load`, and acknowledged callback attempts
with a second CAS write.

That protocol solved "terminal commit succeeded but callback was not observed".
It did **not** solve exactly-once effects. If the process died after the callback
performed an external action but before ACK, the callback could run again.

Therefore the Application still needed idempotency/deduplication. Phronomy would
have been maintaining an outbox-like protocol while being unable to own the
external transaction.

The revised boundary is:

```text
semantic completion              Phronomy
same-process event observation   Runtime
external side effect             Application
restart-spanning notification    Application outbox/job/Workflow when required
```

Process loss after semantic terminal commit but before `on_event` is therefore
allowed to lose the callback observation. It must **not** lose or replay the
semantic result.

## 5. Why Team aggregation is replay-safe instead of uncertainty-managed

The earlier design treated arbitrary `aggregate` as an X0 callback:

```text
mark aggregation started
invoke callback
if process dies -> outcome unknown -> manual resolution
```

That is appropriate for an arbitrary external effect, but `aggregate` is part of
Team result computation. Letting it perform one-shot external effects makes a
simple result-composition hook behave like an application transaction.

The revised contract is:

- `aggregate` receives canonical durable assignment results;
- it must have no externally observable one-shot side effects;
- repeated invocation with the same canonical inputs must be semantically
  equivalent;
- if the process dies before the aggregate result is durably committed, Phronomy
  may call `aggregate` again;
- external actions based on the Team result happen **after** Team completion in
  Application code.

This removes `aggregation=started`, unknown-outcome recovery and manual
aggregation resolution.

## 6. Why standalone Orchestrator fan-out is Runtime-only

`Orchestrator` already has a canonical durable root when it is executing as an
Agent:

```text
Orchestrator AgentRoot
  -> Orchestrator AgentExecution
     -> durable child coordination snapshot
```

A direct Application call to:

```ruby
orchestrator.dispatch_parallel(...)
orchestrator.fan_out(...)
```

has no such parent execution.

The previous plan created a synthetic private AgentExecution only to make this
convenience method durable. That:

- changed Agent admission semantics;
- restricted arbitrary invocation-only Agent classes;
- required a new direct-fan-out recovery mode;
- made a helper method participate in durable execution identity merely to satisfy
  a blanket "everything durable" statement.

The revised rule is:

```text
inside an existing Orchestrator AgentExecution
  -> durable child coordination

direct standalone convenience call
  -> Runtime-only; current-process completion only
```

If an Application requires durable fan-out, it should run it through an
Orchestrator AgentExecution or model the application process as a Workflow.

## 7. Handoff remains framework-durable

Handoff is not an Application notification problem.

If Phronomy exposes "active responsibility moved A -> B", then process loss must
not make the framework forget that B is active and rerun A merely to rediscover
the route.

Therefore Phronomy continues to own:

- `main_agent.agent_id` as the durable Handoff routing anchor;
- durable active Agent identity;
- immutable transferred HandoffContext reference;
- reserved exact Target `execution_id`;
- target absent/active/terminal reconciliation;
- multi-hop routing state.

Application code still owns the current Handoff graph and Policy objects and must
re-supply compatible wiring after restart.

## 8. TeamCoordinator remains durable, but only for Team semantics

The TeamCoordinator durable scope is retained because Phronomy itself owns the
queue/assignment/worker abstraction.

Phronomy therefore persists:

```text
TeamRoot
TeamExecution
canonical task records
worker slot identities
task -> worker assignment
reserved worker Agent/execution IDs
worker terminal result/error
final Team result/error
```

It does **not** persist:

```text
scheduler Proc
aggregator Proc
stream callbacks
terminal callbacks
Task handles
FSMSession
external side effects
```

This is a deliberate product boundary. If durable Team semantics still proves
disproportionately expensive after these reductions, implementation must stop and
report that fact rather than silently expanding framework responsibilities again.

## 9. Persistence consequence

The durable root still expands to:

```text
contents
agents
journals
executions
workflow_states
handoff_states
teams
team_executions
```

However the following previous additions are removed:

```text
executions.list_delivery_pending
execution delivery_pending backend index
team_executions.list_delivery_pending
Team terminal-delivery descriptor/index
```

No second CAS terminal-delivery ACK protocol is required.

## 10. Recovery consequence

Recovery is now about semantic execution/coordination only:

```text
Agent
  active/nonterminal execution recovery

Handoff
  active responsibility / exact Target continuation

Orchestrator
  existing parent AgentExecution + exact child reconciliation

Team
  active TeamExecution + task/assignment/worker reconciliation
```

It is **not** responsible for reconstructing missed Application callback delivery.

## 11. Explicit non-goals

This redesign does not provide:

- exactly-once Provider, Tool, callback, webhook, email or database effects;
- restart-spanning delivery of arbitrary callbacks;
- recovered process-local Tasks;
- a distributed transaction across external systems;
- persistence of Ruby Classes, Procs, callbacks, FSMSessions or EventLoop queues;
- durable semantics for every convenience method simply because it exists.

## 12. Acceptance criterion for future implementation work

Before adding any new durable field/protocol, ask:

> If this state is lost, does Phronomy risk rerunning or misrouting semantic work
> that Phronomy itself owns?

If **no**, the state should normally remain Runtime/Application responsibility.

If **yes**, add the smallest purpose-specific durable fact needed to reconcile it.

## 13. Accepted clarification after V2 review

The five accepted [recovery contracts](RECOVERY_CONTRACT_CLARIFICATIONS.md)
make the existing responsibility boundary testable:

1. Read-only outcome access and retained execution discovery replace reliance on
   callback observation, without promising notification delivery or request dedup.
2. Failed reads and unknown commit outcomes never authorize replacement work;
   use existing authoritative reads, atomic admission and CAS reconciliation.
3. Declared definition/slot/graph compatibility is checked before continuation;
   committed facts outrank changed current wiring. Code compatibility is an
   Application obligation, not Proc serialization or code hashing.
4. Observation loss/shutdown and semantic cancellation are distinct. Cancellation
   respects exact owned child executions and existing Agent terminal barriers.
5. Durability means confirmed outcome reuse and exact execution recovery;
   unknown external effects remain under existing Agent Recovery, not exactly once.

These are implementation contracts within the accepted scope. No callback outbox,
standalone synthetic parent, generic registry or second Team engine is authorized.
