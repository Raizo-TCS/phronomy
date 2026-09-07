# Durable semantic coordination V2 migration

This Beta clean break applies to baseline `5472116cd99a63ec27875024c955ea82be612d6b`.

| Previous surface | Current surface |
|---|---|
| `MultiAgent::Handoff`, `HandoffPolicy`, `Runner` | `Agent::Handoff`, `HandoffPolicy`, `HandoffRunner` (no aliases) |
| Runtime-local Handoff routing | HandoffState at original main Agent ID; same Persistence domain required |
| Anonymous Team/new Runtime queue | Explicit `team_definition id:, version:` and stable `team_id`; TeamRoot/TeamExecution |
| Arbitrary aggregate object/error exception result | Pure replay-safe aggregate, canonical JSON result/error data |
| Five backend repositories | Eight mandatory repositories; extend root and transaction views |
| Direct standalone fan-out | Remains Runtime-only; no synthetic parent AgentExecution |

```ruby
class WorkTeam < Phronomy::MultiAgent::TeamCoordinator
  team_definition id: "work-team", version: 1
  coordinator_model "gpt-4o-mini"
  coordinator_provider :openai
  pool size: 2, agent: WorkerAgent
  aggregate { |assignments| assignments.map { |a| a[:result] }.compact.join("\n") }
end

team = WorkTeam.create(team_id: "team-42", persistence: store)
value = team.invoke("Prepare the report")
runs = store.list_team_executions("team-42")
run_id = runs.first.team_execution_id
retained = store.team_execution_result(run_id)
# After a restart with the same declared Team and worker definitions:
team = WorkTeam.load("team-42", persistence: store, on_event: recovery_listener)
value = team.resume(run_id)
```

`resume` consumes a stored terminal outcome without running the aggregator again.
For unfinished runs, stored input/context/assignments and child reservations win.
Compatible current Agent/Team classes, static registrations and Handoff graph are
execution wiring, not serialized objects. Version matching checks declarations;
Application must change versions for incompatible behavior and retain compatible
wiring for old runs. It is not a source-code hash or automatic migration system.

Use `Persistence#execution_result(id)` and owner-scoped `list_executions` for Agent
results without hydration/callbacks. `Persistence#handoff_result(source_id)`
follows the exact transfer chain without constructing a graph or Agent owners. `Orchestrator#resume(id)` continues existing
static subagent coordination. There is no global generic class registry.

Observer Task wait timeouts and shutdown do not request cancellation. Team's
`cancel(run_id)` persists a run-scoped request before forwarding its live token;
resume settles exact children or returns the existing rehydration error. Handoff's
`cancel(execution_id)` follows only that turn. A cancellation token passed to
invoke remains the existing Agent execution cancellation mechanism; it does not
promise rollback of external effects. Persisted pending child IDs remain
available for recovery when external factual resolution is required.

Callbacks and streaming progress may be lost after Runtime/process loss.
Application notifications, outboxes, retries and external-effect deduplication
belong to Application. No callback delivery ACK or restart replay is added.
InMemory is useful for tests but a durable backend is required for actual F4
storage retention. See ADR-018 and the V2 RC contract for guarantee limits.

The existing `Agent#purge!` removes its own Handoff anchor atomically with its
Agent records, after the anchor has no pending/active turn. Referenced outcomes
deleted through retention/purge are unavailable, not evidence of a new reservation.
Do not purge participating child/Target owners while their coordination is active.
Team `stream` observes committed assignment progress; the construction `on_event`
listener is passed to hidden Agents for their current Runtime events and Recovery.
There is no additional Team callback delivery subsystem.
