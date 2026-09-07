# Phronomy Durable Semantic Coordination — Implementation Design V2

## 0. Status and authority

**Accepted implementation design — V2 revision 2 (2026-09-06).**

This revision incorporates the user-approved five recovery-contract clarifications.
The implementation targets the fixed baseline below. Measured validation and
API/SPI mappings are recorded in [IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md).

Baseline:

```text
repository: Raizo-TCS/phronomy
commit:     5472116cd99a63ec27875024c955ea82be612d6b
```

This V2 design supersedes the earlier "Complete Durability" working implementation
plan.

The V2 boundary and this revision are approved. No renewed design approval is
required. Implementation resumes only from verified baseline and source artifacts;
Stop Conditions still apply.

## 1. Design objective

The implementation target is:

> Preserve Phronomy-owned semantic execution/coordination progress across
> process/runtime loss, without blindly repeating confirmed semantic work.

It is **not**:

> make every callback, Task, convenience API or external side effect durable.

## 2. Responsibility boundary

### 2.1 Phronomy durable authority

```text
AgentExecution semantic facts
Handoff routing state
Orchestrator child coordination attached to an existing AgentExecution
TeamRoot / TeamExecution
Team tasks, assignments, reserved worker identities and worker outcomes
```

### 2.2 Runtime/Application authority

```text
on_event callbacks
Tasks
stream callbacks
scheduler/aggregator Proc objects
FSMSessions
EventLoop routing/admission tokens
standalone convenience fan-out state
email/webhook/database effects
external side-effect idempotency
```

## 3. Cross-cutting invariants

### 3.1 Persist facts, never Runtime objects

Never persist:

```text
FSMSession / fsm_session_id
Task
callback / Proc
Ruby Class object
AgentInvocation
EventSink
EventLoop queue/admission token
Mutex / Thread / Fiber
CancellationToken object
```

### 3.2 EventLoop remains the live-state writer

New durable operations follow:

```text
EventLoop
  -> immutable operation command
Offload
  -> blocking Persistence transaction/reconciliation
EventLoop
  -> authority validation + live apply + next Runtime action
```

### 3.3 Confirmed semantic work is not replayed

Use durable evidence before deciding to invoke:

```text
Provider/Tool recovery rules already owned by Agent
Handoff Source/Target
Orchestrator child AgentExecution
Team worker AgentExecution
```

### 3.4 Exact recovery does not mean exactly-once external effects

Reuse confirmed durable outcomes. Recover unfinished work under the same semantic
execution identity. Resolve unknown Provider/Tool effects through existing Agent
Recovery. A successful authoritative absence read plus confirmed admission is
required before starting an absent reserved execution. Read/commit errors do not
establish absence; preserve IDs and reconcile using existing Persistence rules.

### 3.5 Application effects are not promoted into framework transactions

Do not introduce durable protocols merely to retry:

```text
on_event
stream callback
email/webhook
arbitrary DB side effect
```

When an Application needs those effects to survive restart, it owns the durable
mechanism.

## 4. Persistence SPI

### 4.1 Root surface

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

All record repositories participate in the same `atomic_all` transaction domain.

### 4.2 Removed from the previous design

Do **not** add:

```text
executions.list_delivery_pending
execution delivery_pending raw metadata/index
team_executions.list_delivery_pending
Team/Agent terminal-delivery descriptors
callback ACK revisions
```

### 4.3 `handoff_states`

Purpose-specific repository:

```ruby
load(main_agent_id)
save(
  main_agent_id,
  expected_revision:,
  next_revision:,
  active_agent_id:,
  record:
)
delete(main_agent_id, expected_revision:)
```

Current-format record type:

```text
phronomy.handoff_state 0.1
```

### 4.4 `teams`

```ruby
create(root)
load(team_id)
save(team_id, expected_revision:, root:)
delete(team_id)
```

Record type:

```text
phronomy.team_root 0.1
```

### 4.5 `team_executions`

```ruby
create_active(execution)
load(team_execution_id)
save(team_execution_id, expected_revision:, execution:)
list_active(team_id)
delete(team_execution_id)
delete_for_team(team_id)
assert_idle!(team_id)
```

Raw metadata includes only identity/revision/active indexing needed by backend.

No delivery-pending metadata.

Record type:

```text
phronomy.team_execution 0.1
```

## 5. Agent terminal behavior

No new terminal-delivery subsystem.

Terminal flow remains:

```text
semantic terminal operation
  -> durable terminal transaction
  -> EventLoop apply/release admission
  -> optional same-process callback
  -> same-process Task settlement
```

Process loss after durable terminal commit may lose callback/Task observation.

Recovery must never replay terminal semantic work merely to reproduce those
observations.

No `:completing` status.

## 6. Handoff implementation

### 6.1 Public clean break

```text
Phronomy::Agent::Handoff
Phronomy::Agent::HandoffPolicy
Phronomy::Agent::HandoffRunner
```

Old `Phronomy::MultiAgent` Handoff public constants are removed, with no aliases
unless separately approved.

### 6.2 HandoffState

Fields:

```text
main_agent_id
handoff_revision
active_agent_id
active_handoff_context_ref
phase: stable | target_pending | target_active
pending_source_execution_id
pending_target_execution_id
created_at
updated_at
metadata
```

### 6.3 HandoffContext

Canonical `to_h/from_h` for:

```text
HandoffContext
HandoffContext::Item
HandoffContext::Provenance
```

Store via ContentStore. Do not adopt into Target Journal/Knowledge automatically.

### 6.4 Source transfer transaction

Capture a value-only Handoff commit specification from current Runtime wiring:

```text
main_agent_id
target_agent_id
reserved_target_execution_id
responsibility
selection_intent
handoff_policy_value
source_manifest_ref
expected_handoff_revision
```

Transaction:

```text
Source Journal terminal/audit facts
Source AgentExecution -> handed_off
Source AgentRoot
HandoffContext content
HandoffState -> target_pending + exact Target execution reservation
```

No callback delivery state.

### 6.5 Target reconciliation

For `pending_target_execution_id`:

```text
Authoritative NotFound after a successful read
  -> confirm current parent/owner/cancellation state
  -> atomically admit exactly that execution ID before semantic work

active/nonterminal
  -> recover the exact execution
  -> stabilize target_active

terminal
  -> consume durable outcome
  -> stabilize HandoffState
  -> never create replacement semantic work
```

On unknown transfer/admission/stabilization commit outcome, read back the same
reserved identities. A failed read is not NotFound. See RC-02.

### 6.6 Handoff-managed Agent recovery

Generic `Agent.load` may hydrate the Agent, but continuation requiring Handoff
graph wiring must wait for compatible `HandoffRunner`.

Do not persist graph/Policy Ruby objects.

### 6.7 Multi-hop

Every later transfer updates the same HandoffState keyed by original
`main_agent.agent_id`.

## 7. Orchestrator implementation

### 7.1 Durable scope

Durable child coordination exists only when there is an existing parent
Orchestrator AgentExecution.

Use:

```text
AgentExecution.metadata["multi_agent_coordination_ref"]
```

to reference an immutable coordination snapshot.

### 7.2 Coordination snapshot

```text
kind
phase
max_concurrency
on_error
children[]
```

Child:

```text
slot
agent_definition_id/version
agent_id
execution_id
input_ref
durable_config_ref
state: reserved | active | completed | failed | skipped
result_ref
error_ref
```

### 7.3 Child reservation

Before child semantic work:

```text
reserve agent_id
reserve execution_id
persist parent snapshot
then create/load child
then start exact reserved execution
```

Child completion Task/callback is only a Runtime wake-up.

Parent reconciliation re-reads the exact child AgentExecution and persists the
authoritative child result/error before advancing the reconstructed FSM.

### 7.4 Stable child wiring

Durable child definitions are resolved from static/current Orchestrator wiring.

Do not persist Ruby Class handles. Apply RC-03 definition id/version and slot
compatibility checks; retain committed child inputs/config rather than current
defaults. Do not infer semantic code equivalence from matching versions.

### 7.5 Standalone convenience calls

Do not create synthetic AgentExecutions for:

```ruby
orchestrator.dispatch_parallel(...)
orchestrator.dispatch_parallel_async(...)
orchestrator.fan_out(...)
orchestrator.fan_out_async(...)
```

when invoked outside a parent Orchestrator AgentExecution.

These retain Runtime-only semantics.

This also means direct convenience calls do **not** need the durable-path static
child-definition restriction.

### 7.6 Durable fan-out usage

Applications requiring restart-durable fan-out use:

```text
Orchestrator Agent invocation + registered subagent Tool/wiring
```

or an explicit Workflow for application process orchestration.

## 8. TeamCoordinator implementation

### 8.1 Identity

Concrete Team class declares:

```ruby
team_definition id: "research-team", version: 1
```

One logical Team instance:

```text
team_id
```

One run:

```text
team_execution_id
```

### 8.2 TeamRoot

```text
team_id
team_definition_id/version
team_revision
lifecycle_status
created_at/updated_at
metadata
```

### 8.3 TeamExecution

Keep only semantic durable facts, for example:

```text
team_execution_id
team_id
execution_revision
status / phase
input_ref
tasks
workers
assignments
result_ref
error_ref
created_at/updated_at
metadata
```

Do not include:

```text
terminal_delivery
aggregation started/unknown resolution state
callback state
```

### 8.4 Stable task-generation coordinator Agent

Replace random per-invoke coordinator definition identity with stable definition
derived from Team class definition.

Coordinator Agent itself uses normal Agent durability/recovery.

### 8.5 Durable enqueue/finalize

`enqueue_task` writes canonical task records into TeamExecution. Authorized
framework operations in one saved Tool batch commit in Provider order in the same
Team transaction; `finalize` cannot overtake an earlier `enqueue_task`. The stable
Tool invocation IDs retain each operation result for exact reconciliation.

`finalize` marks task generation complete.

Once a task exists durably, recovery does not ask coordinator Agent to recreate it.

### 8.6 Worker assignment reservation

Before worker semantic execution:

```text
select available worker
reserve worker agent_id for TeamExecution slot
reserve exact worker execution_id
commit task -> worker assignment
then start/recover that exact execution
```

### 8.7 Scheduler contract

`schedule` is Application code but must be replay-safe:

```text
no external one-shot side effects
may rerun until assignment is committed
after assignment commit it is not rerun for that task
```

### 8.8 Worker completion

Wake-up callbacks are non-authoritative.

Reconcile exact reserved worker execution from Persistence and then persist
TeamExecution worker/task outcome.

### 8.9 Aggregator contract

`aggregate` is pure/replay-safe result computation.

Input is canonical durable assignment results.

If the process dies before result/error commit:

```text
run aggregate again
```

No `aggregation=started`, unknown outcome or manual resolution.

On normal return/raise:

```text
persist result_ref/error_ref
terminalize TeamExecution
TeamRoot -> idle
```

### 8.10 Team callbacks

Progress and terminal callbacks are Runtime-only observations.

No restart-spanning delivery state/index.

## 9. Runtime ownership

### 9.1 Handoff

Same-process HandoffRunner admission prevents competing live controllers for the
same main Agent/graph.

### 9.2 Team

If Team is made a stable logical entity, Runtime needs process-local ownership
similar in intent to Agent ownership:

```text
create/load/get by team_id
one live owner per Runtime
definition compatibility
shutdown draining
```

This registry must not become durable authority; TeamRoot/TeamExecution remain
Persistence authority.

If implementing this registry remains disproportionately complex after the scope
reductions above, stop and report before adding more abstraction.

## 9A. Accepted recovery contract obligations

[RECOVERY_CONTRACT_CLARIFICATIONS.md](RECOVERY_CONTRACT_CLARIFICATIONS.md) is a
normative part of this design, not an optional follow-up plan.

| Contract | Implementation obligation |
|---|---|
| RC-01 | Public read-only exact execution status/result access and discovery from known owner identity, including retained terminal executions; no implicit continuation/callback/admission |
| RC-02 | Distinguish authoritative absence, conflict, failed read and unknown commit; preserve operation/Agent/execution IDs and reconcile before further semantic work |
| RC-03 | Check declared definition compatibility and current required graph/slot wiring; reuse committed facts; Application owns semantic code compatibility |
| RC-04 | Separate observer detach/shutdown from semantic cancel; map cancellation/admission/settlement and restart discovery to existing Agent contracts |
| RC-05 | Reuse confirmed outcomes, recover unfinished exact executions, resolve unknown external effects using existing Agent Recovery |

API method names are not invented in this documentation update. Before coding,
map each requirement to baseline public APIs/SPI, implementation and specs. Add
only genuinely missing capability. Record retention, discovery ambiguity and
cancel/terminal ordering explicitly in that mapping. A version declaration is
not permission to resume incompatible code or migrate stored records silently.

## 10. Transaction boundaries

| Semantic boundary | One durable transaction contains |
|---|---|
| Agent normal terminal | existing terminal Agent facts/result/error; **no callback state** |
| Source Handoff | Source terminal facts + HandoffContext + HandoffState Target reservation |
| Handoff Target stabilization | Target Agent terminal facts + HandoffState stabilization when applicable |
| Orchestrator child reservation | parent snapshot with reserved child Agent/execution IDs |
| Orchestrator child outcome | parent snapshot consumes exact child terminal outcome |
| Team admission | TeamExecution create_active + TeamRoot active |
| Team enqueue | canonical task |
| Team assignment | task -> worker slot + exact reserved worker execution |
| Team worker outcome | exact worker terminal result applied to TeamExecution |
| Team aggregate result | final result/error ref after replay-safe aggregate returns/raises |
| Team terminal | TeamExecution terminal + TeamRoot idle |

No callback ACK transaction exists. Every row is subject to RC-02: a lost write
acknowledgement must be reconciled using existing Persistence mechanisms before
advancing dependent semantic work. RC-04 cancellation is mapped to existing
Agent cancellation/terminal barriers; this table does not create a second
transaction or cancellation engine.

## 11. Failure/recovery matrix

### 11.1 Agent callback boundary

| Failure point | Result |
|---|---|
| before terminal commit | normal active recovery |
| terminal committed, before callback | semantic result remains terminal; callback may be lost |
| during callback | external effect semantics belong to Application |
| after callback, before caller Task settlement | lost Task observation allowed; no semantic replay |

### 11.2 Handoff

| Failure point | Recovery |
|---|---|
| before Source transaction | recover Source |
| after Source transaction, Target absent | start exact reserved Target execution |
| Target active | recover same execution |
| Target terminal, HandoffState not stabilized | consume exact terminal and stabilize |
| graph wiring absent | fail closed |

### 11.3 Orchestrator durable path

| Failure point | Recovery |
|---|---|
| child reserved, Agent absent | create reserved Agent |
| child Agent exists, execution absent | start reserved execution |
| child active | recover exact child |
| child terminal, parent snapshot stale | consume exact terminal and CAS parent snapshot |
| FSMSession lost | rebuild fresh session from snapshot |

Standalone convenience fan-out has no restart guarantee.

### 11.4 Team

| Failure point | Recovery |
|---|---|
| before task enqueue commit | coordinator Agent recovery may replay generation |
| task enqueue committed | task already exists; do not recreate |
| before assignment commit | scheduler may rerun |
| assignment committed, worker absent | start exact reserved worker execution |
| worker active | recover exact worker |
| worker terminal, TeamExecution stale | consume exact worker outcome |
| aggregate running, process dies | rerun replay-safe aggregate |
| final Team terminal committed, callback missed | semantic result remains terminal; callback may be lost |

### 11.5 Common clarification failure matrix

| Failure/observation | Required behavior |
|---|---|
| Caller lost before receiving committed execution ID | Discover retained active/terminal candidates from known owner; do not infer unique request correlation |
| Read timeout or decode failure | Return an error; do not treat as absence or successful empty result |
| Commit acknowledgement lost | Read back same operation/IDs, reconcile facts, no replacement execution |
| Incompatible/missing current wiring | Fail closed before continuation; read-only outcome access stays independent of execution wiring |
| Observer disappears or Runtime stops | No implicit semantic cancellation |
| Explicit parent cancel races with child admission/completion | Reconcile exact child state through existing cancel/terminal barriers; preserve terminal facts and restart discoverability |

## 12. Source change map

### 12.1 Remove/not implement from previous plan

```text
Agent terminal_delivery helper
delivery_pending execution index
TerminalDeliveryRecovery
callback ACK command/readback
Agent.load terminal delivery drain
Team terminal delivery index
Team aggregation manual-resolution state
synthetic direct-fan-out AgentExecution mode
```

### 12.2 Retain/add

```text
Persistence:
  handoff_states
  teams
  team_executions
  codecs/facades/InMemory/RBS/backend contract

Agent:
  reserved execution start
  Handoff domain + HandoffState recovery wiring

Orchestrator:
  coordination snapshot for existing parent AgentExecution
  exact child reservation/reconciliation
  recovery reconstruction

Team:
  TeamRoot / TeamExecution
  stable coordinator Agent
  durable task/assignment/worker result
  replay-safe scheduler/aggregate contracts
  process-local ownership/recovery adapter
```

## 13. Documentation migration

Revise current docs only after implementation.

Migration notes must explicitly state:

- Handoff namespace clean break;
- same-Persistence durable Handoff graph;
- Team stable identity/create/load APIs if retained;
- durable Team scheduler/aggregate purity/replay contract;
- standalone Orchestrator fan-out remains Runtime-only;
- `on_event` is not restart-spanning.

## 14. Test requirements

### Architecture guards

Assert:

```text
no :completing
no terminal_delivery/delivery_pending persistence surface
no old MultiAgent Handoff public constants
no synthetic direct_fan_out durable parent mode
no persisted Proc/Class/Task/FSMSession
TeamCoordinator not a Workflow subclass
```

### Persistence contract

Test:

```text
handoff_states CAS
teams root revision
team_executions active admission/CAS
atomic_all participation
codec strictness
```

No callback-delivery indexes.

### Fault injection

Required durable failure cases:

```text
Source Handoff commit -> crash before Target start
Target exact execution terminal -> crash before Handoff stabilization
Orchestrator child terminal -> crash before parent snapshot update
Team assignment commit -> crash before worker start
Team worker terminal -> crash before TeamExecution update
Team aggregate invoked -> process loss -> replay-safe rerun
```

Also test intentional non-guarantees:

```text
terminal callback may be lost after process loss
standalone dispatch_parallel has no restart recovery
```

### Recovery-contract acceptance scenarios

Run the RC-01-A through RC-05-A scenarios in
[the clarification test matrix](RECOVERY_CONTRACT_CLARIFICATIONS.md).
Record existing coverage and add only missing behavioral/fault cases. Unknown
commit tests must cover the applicable Handoff, parent snapshot and Team write
boundaries, rather than only a mocked happy-path read. Cancellation tests include
admission/terminal races and process loss. No scenario is marked passed by this
documentation revision.

## 15. Definition of Done

### Agent

- semantic terminal outcome remains durable;
- no callback-delivery durability subsystem;
- lost callback never causes semantic replay.

### Handoff

- Agent namespace clean break;
- durable active responsibility;
- atomic Source transfer + exact Target reservation;
- exact Target recovery;
- multi-hop/later-turn routing survives process loss;
- graph absence fails closed.

### Orchestrator

- coordination inside an Orchestrator AgentExecution has durable child snapshot;
- child IDs are reserved before semantic work;
- exact terminal child outcomes are reconciled;
- fresh runtime FSM is reconstructed;
- standalone direct fan-out is documented/tested Runtime-only.

### Team

- stable Team identity/execution;
- durable tasks/assignments/worker IDs/results;
- exact worker recovery;
- scheduler and aggregate are replay-safe contracts;
- aggregate can be rerun after ambiguous process loss;
- no terminal callback persistence.

### Common

- Persistence is the only framework durable backend abstraction;
- EventLoop remains live single-writer;
- Runtime objects are never serialized;
- Application external effects remain Application responsibility;
- no purpose-unrelated generic identity is introduced;
- RC-01 through RC-05 are mapped to actual baseline APIs/implementation/specs;
- result discovery ambiguity and retention limits are documented;
- cancellation/terminal ordering and restart discovery are verified against existing contracts;
- full focused/backend/fault/full-suite verification passes on the target checkout.

## 16. Stop conditions

Implementation must stop and report rather than expand scope if any of the
following becomes necessary:

1. durable Team semantics require serializing Application Proc/Class objects;
2. durable Orchestrator child recovery requires a global generic class registry;
3. callback durability is reintroduced merely to recover caller observation;
4. a convenience API needs a synthetic semantic identity solely to claim
   "everything durable";
5. Team ownership/recovery requires a second framework execution engine that
   materially duplicates Workflow without clear product value;
6. a semantic transition would require distributed transactions across independent
   Persistence domains.

These are architecture-review triggers, not invitations to add more machinery.
