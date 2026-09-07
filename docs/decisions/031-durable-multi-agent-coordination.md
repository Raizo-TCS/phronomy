# ADR-031: Durable Multi-Agent Semantic Coordination

## Status

Accepted. V2 revision 2, 2026-09-06.

User approval covers the V2 boundary and the five recovery-contract clarifications.
Acceptance is design authority; it is not a claim of repository integration or test success.

## Date

2026-09-06

## Context

Phronomy exposes:

- `MultiAgent::Orchestrator < Agent::Base`, with child Agents/Tools and fan-out
  helpers; and
- `MultiAgent::TeamCoordinator`, with coordinator-generated tasks and a worker pool.

Individual AgentExecutions are durable, but process-local coordination state is
not. Losing child identities, task assignments or confirmed worker outcomes can
cause Phronomy to repeat semantic work it owns.

The previous proposal also attempted to make standalone fan-out convenience APIs,
arbitrary Team aggregation callbacks and terminal Application callbacks durable.
Responsibility review found those parts too broad.

This ADR therefore defines durability at the **framework-owned semantic
coordination boundary**, not at every callback/convenience API boundary.

## Decision

### 1. MultiAgent durability means semantic progress recovery

For a durable MultiAgent operation:

```text
process/runtime loss
  -> reconstruct from durable coordination facts
  -> reuse confirmed child/worker outcomes
  -> recover exact unfinished executions
  -> admit absent reserved executions only after authoritative read/admission
  -> resolve unknown external effects through existing Agent Recovery
```

FSMSession, Task, callback and Runtime queues remain disposable.

### 2. Orchestrator durability is rooted in an existing Orchestrator AgentExecution

`MultiAgent::Orchestrator < Agent::Base` already has canonical Agent identity.

When child coordination occurs **inside an existing Orchestrator AgentExecution**,
that AgentExecution references an immutable coordination snapshot containing, as
needed:

```text
coordination kind / phase
child slot
child Agent definition identity/version
reserved child agent_id
reserved child execution_id
restart-required input/config refs
child semantic state
result_ref / error_ref
on_error / max_concurrency semantic options
```

No separate Orchestrator repository or generic multi-agent execution ID is added.

### 3. Existing fan-out Runtime FSM remains reconstructable machinery

`FanOutInvocation` / `FSMSession` remain Runtime projections.

Recovery builds a fresh runtime invocation/session from the durable coordination
snapshot and fresh Runtime identities.

### 4. Framework-owned child identities are reserved before semantic work

Before a durable Orchestrator child begins:

```text
reserve child agent_id
reserve child execution_id
persist parent child slot + restart-required refs
then create/load child and start exact reserved execution
```

Recovery distinguishes absent/nonterminal/terminal exact child state and never
creates a replacement simply because Runtime callbacks were lost.

### 5. Durable child definitions must be reconstructable from stable wiring

For the durable path, a child Agent class must be resolvable from stable current
Orchestrator/Application wiring, initially the concrete Orchestrator class's
registered subagents.

Invocation-only anonymous/arbitrary class handles are not persisted.

This restriction applies only to APIs/paths that claim restart durability.

### 6. Standalone `dispatch_parallel*` / `fan_out*` remain Runtime-only convenience APIs

A direct Application call to:

```ruby
orchestrator.dispatch_parallel(...)
orchestrator.fan_out(...)
```

outside a live parent Orchestrator AgentExecution does **not** create a synthetic
AgentExecution solely for durability.

It keeps current-process semantics and may continue accepting Runtime-only Agent
class wiring.

If durable fan-out is required, the Application must place the work under:

- an Orchestrator AgentExecution with stable child wiring; or
- an Application Workflow when the operation is application-process
  orchestration.

This avoids inventing durable parent identity for a convenience call.

### 7. Durable framework-owned Orchestrator children share the parent Persistence domain

A durable parent/child coordination path uses the same Persistence domain.

External remote effects reached through Tools/Application integration remain X0
external effects.

### 8. TeamCoordinator is a purpose-specific durable semantic entity

TeamCoordinator remains under `MultiAgent`, not `Agent::Base`.

It gains:

```text
team_id
team_execution_id
team_definition id/version
TeamRoot
TeamExecution
```

This is retained because Phronomy itself owns the Team queue/assignment/worker
abstraction.

### 9. Team task queue and worker assignment are durable facts

TeamExecution durably records:

```text
canonical tasks
task-generation finalized state
worker slots / stable worker agent_id
task -> worker assignment
reserved worker execution_id
worker terminal result/error
final Team result/error
```

Before worker semantic execution starts, its assignment and reserved exact
execution identity are committed.

### 10. Worker identity is stable within one TeamExecution

A worker slot reuses its logical Agent identity for that TeamExecution so worker
context/transcript semantics remain coherent across assigned tasks.

This ADR does not require worker identity/history to survive into another
TeamExecution.

### 11. Team scheduler is a replay-safe decision function

Application `schedule` may run again while no assignment has been durably
committed.

Contract:

- it must not perform externally observable one-shot effects;
- it selects from the supplied available worker projection;
- repeated execution before assignment commit is allowed;
- after assignment commit, recovery uses the durable assignment and does not
  rerun scheduling for that task.

No scheduler result needs a separate unknown-outcome protocol.

### 12. Team aggregation is pure/replay-safe result computation

Application `aggregate` receives canonical durable assignment results.

Contract:

- no externally observable one-shot side effects;
- repeated invocation with the same canonical assignments must be semantically
  equivalent;
- if process loss occurs before aggregate result/error is durably committed,
  Phronomy may invoke `aggregate` again;
- on normal return/raise, Phronomy durably records the final result/error before
  Team terminalization.

There is no `aggregation=started -> outcome unknown -> manual resolve` protocol.

Applications perform external post-Team effects after obtaining/reconciling the
Team result.

### 13. Team progress and terminal callbacks are Runtime-only

Streaming task-completion callbacks and final Application notifications are
current-process observations.

Canonical task/worker/Team semantic outcomes are durable; callback delivery is
not.

No Team delivery-pending index or restart redelivery obligation is introduced.

### 14. Workflow remains the Application process-orchestration domain

Public domain ownership remains:

```text
Agent
  Agent semantic execution + Agent Handoff

MultiAgent
  durable framework-owned Orchestrator child coordination
  durable Team queue/assignment/worker coordination
  Runtime-only convenience fan-out outside a durable parent

Workflow
  explicit Application-defined durable process/state-machine orchestration
  durable ordering of Application-owned steps/effects when modeled by the app
```

### 15. Recovery contract clarifications

The normative [RC-01 through RC-05 contracts](../design/durable-semantic-coordination/RECOVERY_CONTRACT_CLARIFICATIONS.md)
apply to existing Orchestrator executions and Team executions:

- expose read-only status/result access and retained execution discovery;
- distinguish authoritative absence from read failure/unknown commit outcome;
- reconcile writes with the same reserved identities using existing Persistence
  protocols, including Team-owned operation facts;
- verify declared definition id/version, registered slot wiring and reserved
  owner/Agent/execution identities before continuation;
- preserve committed inputs/config, assignments and outcomes instead of
  recalculating them with changed current code;
- distinguish observation loss/shutdown from semantic cancellation;
- stop new dispatch on accepted parent-run cancellation, reconcile already
  admitted children using existing Agent cancellation and terminal barriers,
  retain terminal outcomes and exact identities needed after restart;
- restrict cancellation to the current run's owned children, never unrelated
  executions or later runs.

Stable version declarations do not prove Ruby code equivalence. Application code
must maintain declared compatibility; no Proc hash or generic registry is added.
Uncommitted replay-safe schedule/aggregate computation remains replayable.
No dedicated cancellation execution engine or callback recovery service is added.

## Persistence changes

The durable root surface expands to include:

```text
handoff_states
teams
team_executions
```

Orchestrator continues to use Agent repositories.

No execution/team terminal-delivery pending index is added.

## Required invariants

1. Durable coordination is claimed only where a durable semantic root exists.
2. Confirmed child/worker terminal work is never blindly rerun.
3. Child/worker semantic work begins only after exact recoverable identity is
   durably known.
4. Orchestrator durable child coordination uses its existing AgentExecution.
5. Standalone convenience fan-out is explicitly Runtime-only.
6. Team has stable identity/execution and durable tasks/assignments/worker results.
7. Scheduler and aggregator are replay-safe Application functions, not arbitrary
   side-effect transaction boundaries.
8. Callback/Task/FSMSession/Proc objects are never persisted.
9. Workflow remains the appropriate domain for Application-defined durable process
   orchestration.

## Non-goals

This ADR does not:

- make standalone convenience fan-out restart-durable;
- make external Provider/Tool/Application effects exactly once;
- persist scheduler/aggregator Procs or callbacks;
- provide restart-spanning Team callback delivery;
- require worker history across TeamExecutions;
- add a generic global Agent class registry;
- turn MultiAgent into a public Workflow alias.
