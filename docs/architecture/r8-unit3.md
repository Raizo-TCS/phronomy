# r8 unit 3: Persistence ownership and Team/Agent operations

This is a candidate based on core `a82974a7fd2360a13af71831a0c3ddc75942fae3`
and examples `70b7244c9f6542062849869a7106c5a627868a80`. It implements P01 and
removes concrete adapter selection from the unit 2 admission framework. P04 is
partially implemented for Team authorization and scheduling. It is not completion
of the full contract architecture.

## Ownership and public application construction

```ruby
stores = Phronomy::PersistenceComposition.in_memory
# Or: PersistenceComposition.build(backend: configured_storage_backend)

Phronomy.configure do |config|
  config.agent_store = stores.agent
  config.team_store = stores.team
  config.workflow_store = stores.workflow
end

agent = MyAgent.create(persistence: stores.agent)
team = MyTeam.create(persistence: stores.team)
workflow = Phronomy::Workflow.define(MyContext, persistence: stores.workflow) do
  # Workflow definition
end

agent_result = stores.agent.result(agent_execution_id)
team_result = stores.team.result(team_execution_id)
```

For an isolated Agent, `PersistenceComposition.agent(backend: optional_backend)`
constructs only the Agent/content components. Ordinary Agent defaults use this
factory. A composition result is a construction bundle, not a query or execution
service; pass only the relevant component to each consumer.

| Owner | Operation / responsibility |
|---|---|
| `Persistence` | `atomic`, scope validity, participation and outer commit |
| `Agent::Store` | Agent result/list/presence/authorization operations, injected Agent record protocol |
| `MultiAgent::Store` | Team result/list operations, injected Team record protocol and Agent public operations |
| Workflow checkpoint port | `load`, `save`, `delete` with instance ID and expected revision |
| Domain `persistence/` implementations | physical resource schema, records, codecs and guards |
| `PersistenceComposition` | selects backend and adapters, validates schemas and binds components |

The stores are roles inside the existing domain framework, not new independent
contracts. Logical acceptance and state-transition decisions remain in Admission,
TeamCoordinator, and the owning domain operations. Record accessors on stores are
internal protocols for their own domain, not cross-domain application APIs.
Common Persistence neither knows these types nor imports composition.

## Atomic participation remains unchanged

The parent reservation is committed first. At child acceptance, the parent guard
is acquired before reading the current reservation, then Agent input/execution
and root revision are written in that same scope. The parent's domain owns its
reservation/cancellation/identity checks. Agent does not interpret parent schemas.
Only after the outer commit does Agent expose its accepted state and start work.

Domain adapters are injected at construction and receive the exact scope's view.
They never select another connection or commit independently. The coordinator
identity, same-thread lifetime, savepoint behavior, conflict classification,
rollback, and uncertain-commit behavior remain in force. LLM/Tool work and async
waiting remain outside these short transactions. Wrapping ordinary async invoke
in an application transaction is not a newly supported API.

## Team uses Agent authorization, not execution metadata

`Agent::Store#authorized_operations(scope, agent_id:, execution_id:,
invocation_id:, name:, arguments:, names:)` validates the exact requested call
against one persisted execution snapshot in the caller's scope. It checks the
Agent owner, invocation identity, authorization state, name, arguments and
requested operation family. It returns immutable `AuthorizedOperation` values
with only `invocation_id`, `name`, and `arguments`, in Provider order.

Team applies these operations and owns its durable operation-result ledger.
A committed replay returns that ledger result without reapplying the batch.
`finalize` cannot overtake earlier authorized `enqueue_task` calls. A mismatch
raises `Persistence::StateConflictError` before Team's changes commit.
`Agent::Store#exist?` reports authoritative absence; failed reads still raise.

Team scheduling now uses its own retained assignment count. The default chooses
the worker with the fewest assignments, breaking ties in worker order. Custom
schedulers receive `WorkerState#assignment_count` instead of `transcript_size`.
The count is derived from existing assignments, including failures; there is no
extra mutable counter and no Agent journal read. This deliberately changes the
default balancing metric. It does not estimate tokens, duration or resource load.

## Removed APIs and directories

- `Persistence.in_memory`, common `transaction`, `capabilities`, repository
  accessors, result/list queries and Agent watermark facade methods are removed.
  `Persistence.new(backend:)` constructs only the neutral coordinator.
- Domain result queries are `stores.agent.result` / `.runs` and
  `stores.team.result` / `.runs`; Handoff observation remains on the Agent store
  pending the ownership work below.
- `Configuration#persistence` is replaced by `agent_store`, `team_store`, and
  `workflow_store`; explicit `persistence:` arguments accept the relevant port.
- The all-domain `PersistenceComposition::Repositories` and the fixed admission
  adapter classes are deleted. There are no legacy API aliases.
- `persistence/api/` and the six-file `persistence/contract/` error subdivision
  are removed. Shared failures are in `persistence/errors.rb`.
- Team/Workflow schema declarations are consolidated into their existing domain
  `persistence/` directories; their separate `storage_contract/` directories and
  root schema constants are removed.

Storage SPI 2 and physical SQL tables/indexes are unchanged. Existing Agent,
Handoff and Workflow record codecs are unchanged. New Team worker entries omit
`transcript_size`; older entries can still be decoded and the unused field is
ignored by scheduling. Assignment history remains the authority. This does not
add an API compatibility wrapper or change saved operation results.

## Remaining work (explicitly not claimed complete)

1. Subagent and Handoff still interpret Agent execution/routing records and
   coordination data. Storage adapter class selection has been removed, but
   renaming raw record access does not make it a proper public domain operation.
   Resolve logical ownership, cancellation, responsibility transfer and restart
   together before changing these paths; existing atomic transfer is preserved.
2. Orchestrator's preparation/resume integration still accesses Agent-owned
   execution and context details. Team's new operation projection is not a
   general solution to those ownership questions.
3. Domain-to-FSM connections, durable Workflow child protocols, multi-record
   uncertain-commit evidence and the remaining semantic dependency review are
   outside this implementation unit. Workflow FINISH translation already exists.
4. PostgreSQL concurrency verification for this candidate requires the matching
   core/examples branch or local PostgreSQL setup. Unit 2 CI evidence is not
   evidence that this candidate has passed PostgreSQL.

The source SVG and full Ruby/RBS evidence report remaining dependencies. Visual
suppression of shared common-value arrows does not remove graph evidence.
